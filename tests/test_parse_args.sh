#!/usr/bin/env bash
# Argument parsing: every flag, and the interactions that are easy to break.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Runs parse_args in a fresh subshell and prints the resulting state as a
# single line of key=value pairs.
parse() {
    (
        lib_source
        set +e
        parse_args "$@"
        validate_args
        printf 'DRY_RUN=%s FORCE=%s SAFETY_NET=%s SSH_MODE=%s ALLOW_IP=%s ENABLE_UFW=%s UFW_PORTS=%s DOCKER_GROUP=%s DOCKER_USER=%s ONLY_F2B=%s SKIP_F2B=%s PAM_VALUE=%s ROLLBACK_DIR=%s' \
            "$DRY_RUN" "$FORCE" "$SAFETY_NET" "$SSH_MODE" "$ALLOW_IP" \
            "$ENABLE_UFW" "$UFW_PORTS" "$DOCKER_GROUP" "$DOCKER_USER" \
            "$ONLY_F2B" "$SKIP_F2B" "$PAM_VALUE" "${ROLLBACK_DIR:-}"
    ) 2>&1
}

# Extracts one field from the line above.
field() { sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p" <<<"$2"; }

echo "parse_args"

out=$(parse)
assert_eq "defaults: DRY_RUN"    "0"          "$(field DRY_RUN "$out")"
assert_eq "defaults: SSH_MODE"   "aggressive" "$(field SSH_MODE "$out")"
assert_eq "defaults: PAM_VALUE"  "yes"        "$(field PAM_VALUE "$out")"
assert_eq "defaults: SAFETY_NET" "0"          "$(field SAFETY_NET "$out")"

out=$(parse --dry-run)
assert_eq "--dry-run" "1" "$(field DRY_RUN "$out")"

out=$(parse --force --skip-fail2ban --disable-pam)
assert_eq "--force"          "1"  "$(field FORCE "$out")"
assert_eq "--skip-fail2ban"  "1"  "$(field SKIP_F2B "$out")"
assert_eq "--disable-pam"    "no" "$(field PAM_VALUE "$out")"

out=$(parse --safety-net 10)
assert_eq "--safety-net 10" "10" "$(field SAFETY_NET "$out")"

out=$(parse --ssh-mode normal)
assert_eq "--ssh-mode normal" "normal" "$(field SSH_MODE "$out")"

# field() splits on spaces, so a multi-token value is asserted on raw output.
out=$(parse --allow-ip "1.2.3.4 10.0.0.0/8")
assert_contains "--allow-ip keeps both tokens" "ALLOW_IP=1.2.3.4 10.0.0.0/8" "$out"

out=$(parse --rollback /root/ssh-backup-20260101-000000)
assert_eq "--rollback" "/root/ssh-backup-20260101-000000" "$(field ROLLBACK_DIR "$out")"

# --allow-port accumulates and implies --enable-ufw
out=$(parse --allow-port 80 --allow-port 443)
assert_contains "--allow-port accumulates"  "UFW_PORTS=80 443" "$out"
assert_contains "--allow-port implies ufw"  "ENABLE_UFW=1"     "$out"

# ---- --docker-group: the optional-argument matrix ----
out=$(SUDO_USER=caio parse --docker-group)
assert_eq "docker: default is SUDO_USER" "caio" "$(field DOCKER_USER "$out")"

out=$(
    env -u SUDO_USER bash -c '
        export SSH_HARDENING_SOURCE_ONLY=1
        source "$1"
        parse_args --docker-group
        printf "DOCKER_USER=[%s]" "$DOCKER_USER"
    ' _ "$SCRIPT" 2>&1
)
assert_eq "docker: no sudo falls back to root" "DOCKER_USER=[root]" "$out"

out=$(SUDO_USER=caio parse --docker-group deploy)
assert_eq "docker: explicit user" "deploy" "$(field DOCKER_USER "$out")"

out=$(SUDO_USER=caio parse --docker-group --safety-net 10)
assert_eq "docker: does not swallow the next flag" "caio" "$(field DOCKER_USER "$out")"
assert_eq "docker: next flag still parsed"         "10"   "$(field SAFETY_NET "$out")"

out=$(SUDO_USER=caio parse --safety-net 10 --docker-group)
assert_eq "docker: last position" "caio" "$(field DOCKER_USER "$out")"

# ---- errors ----
out=$(parse --nope)
assert_contains "unknown option dies" "unknown option: --nope" "$out"

summary
