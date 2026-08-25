#!/usr/bin/env bash
# --docker-group behaviour (PR 3).
#
# setup_docker_group lives below the sourcing guard, so these run the script
# end to end. --only-fail2ban --skip-fail2ban isolates the docker section:
# the sshd block is skipped and fail2ban never starts.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "--docker-group"

if (( EUID != 0 )); then
    printf '  SKIP: needs uid 0 (creates users and groups)\n'
    exit 0
fi

STUBS="$(cd "$(dirname "${BASH_SOURCE[0]}")/stubs" && pwd)"

# Throwaway users for this file only.
U_PLAIN=t_dg_plain
U_MEMBER=t_dg_member
cleanup() {
    userdel -r "$U_PLAIN"  2>/dev/null || true
    userdel -r "$U_MEMBER" 2>/dev/null || true
}
trap cleanup EXIT
cleanup
groupadd -f docker >/dev/null 2>&1
useradd -m "$U_PLAIN"
useradd -m "$U_MEMBER" && usermod -aG docker "$U_MEMBER"

# --force is passed throughout: the confirmation prompt has no tty here, and
# its own behaviour is asserted separately below.
dg() { bash "$SCRIPT" --force --only-fail2ban --skip-fail2ban --docker-group "$@" 2>&1; }

in_docker() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx docker; }

# ---- explicit user ----
out=$(PATH="$STUBS:$PATH" dg "$U_PLAIN")
assert_contains "explicit user: added"     "$U_PLAIN added to the docker group" "$out"
in_docker "$U_PLAIN" && r=yes || r=no
assert_eq       "explicit user: really in the group" "yes" "$r"

# ---- already a member ----
out=$(PATH="$STUBS:$PATH" dg "$U_MEMBER")
assert_contains "already a member: says so" "$U_MEMBER is already in the docker group" "$out"

# ---- nonexistent user ----
out=$(PATH="$STUBS:$PATH" dg t_dg_ghost)
assert_contains "nonexistent user" "no such user: t_dg_ghost" "$out"

# ---- root: no longer aborts, but is called a no-op (PR 3 change) ----
out=$(PATH="$STUBS:$PATH" dg root)
assert_contains "root: warns it grants nothing" "uid 0" "$out"
assert_contains "root: explains why"            "CAP_DAC_OVERRIDE" "$out"
in_docker root && r=yes || r=no
assert_eq       "root: was actually added"      "yes" "$r"
gpasswd -d root docker >/dev/null 2>&1 || true

# ---- default without sudo is now root, not empty (PR 3 change) ----
out=$(
    env -u SUDO_USER PATH="$STUBS:$PATH" \
        bash "$SCRIPT" --force --only-fail2ban --skip-fail2ban --docker-group 2>&1
)
assert_contains "no sudo: falls back to root"      "uid 0"                     "$out"
refute=$([[ "$out" == *"SUDO_USER is empty"* ]] && echo present || echo gone)
assert_eq       "no sudo: old abort message gone"  "gone" "$refute"
gpasswd -d root docker >/dev/null 2>&1 || true

# ---- default under sudo is still the invoking user ----
userdel -r "$U_PLAIN" 2>/dev/null; useradd -m "$U_PLAIN"
out=$(SUDO_USER="$U_PLAIN" PATH="$STUBS:$PATH" \
        bash "$SCRIPT" --force --only-fail2ban --skip-fail2ban --docker-group 2>&1)
assert_contains "sudo: uses SUDO_USER" "$U_PLAIN added to the docker group" "$out"

# ---- confirmation only fires for an implicit target ----
# No tty in this harness, so confirm() returns 2 and the step is skipped.
userdel -r "$U_PLAIN" 2>/dev/null; useradd -m "$U_PLAIN"
out=$(SUDO_USER="$U_PLAIN" PATH="$STUBS:$PATH" \
        bash "$SCRIPT" --only-fail2ban --skip-fail2ban --docker-group </dev/null 2>&1)
assert_contains "implicit target: announces the grant" "root-equivalent access to '$U_PLAIN'" "$out"
assert_contains "implicit target: skips without a tty" "no terminal to confirm on" "$out"
in_docker "$U_PLAIN" && r=yes || r=no
assert_eq       "implicit target: not added when skipped" "no" "$r"

# An explicit target skips the prompt entirely.
out=$(PATH="$STUBS:$PATH" \
        bash "$SCRIPT" --only-fail2ban --skip-fail2ban --docker-group "$U_PLAIN" </dev/null 2>&1)
refute=$([[ "$out" == *"no terminal to confirm on"* ]] && echo prompted || echo direct)
assert_eq       "explicit target: no prompt" "direct" "$refute"
assert_contains "explicit target: added"     "$U_PLAIN added to the docker group" "$out"

# ---- dry-run never touches anything ----
userdel -r "$U_PLAIN" 2>/dev/null; useradd -m "$U_PLAIN"
out=$(PATH="$STUBS:$PATH" bash "$SCRIPT" --dry-run --force \
        --only-fail2ban --skip-fail2ban --docker-group "$U_PLAIN" 2>&1)
assert_contains "dry-run: prints the command" "(dry-run) usermod -aG docker $U_PLAIN" "$out"
in_docker "$U_PLAIN" && r=yes || r=no
assert_eq       "dry-run: did not add"        "no" "$r"

# ---- regression: no controlling terminal ----
# '[[ -r /dev/tty ]]' passes even with no controlling terminal; opening it then
# fails with ENXIO. The script used to die on 'resp: unbound variable' instead
# of telling you to use --force. Present in the code before this PR too.
out=$(PATH="$STUBS:$PATH" setsid bash "$SCRIPT" \
        --only-fail2ban --skip-fail2ban --docker-group "$U_PLAIN" </dev/null 2>&1)
refute=$([[ "$out" == *"unbound variable"* ]] && echo crashed || echo handled)
assert_eq "no tty: no crash on an unbound resp" "handled" "$refute"

summary
