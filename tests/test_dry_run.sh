#!/usr/bin/env bash
# End-to-end --dry-run with stubbed system tools.
#
# Uses --only-fail2ban so the sshd section is skipped: that section reads and
# writes the real /etc/ssh, which is not something a unit test should touch
# even in dry-run. Sections 12 (ufw) and 13 (fail2ban) still run in full.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "dry-run (end to end)"

if (( EUID != 0 )); then
    printf '  SKIP: needs uid 0 (the script refuses to run otherwise)\n'
    exit 0
fi

STUBS="$(cd "$(dirname "${BASH_SOURCE[0]}")/stubs" && pwd)"

out=$(PATH="$STUBS:$PATH" bash "$SCRIPT" \
        --dry-run --only-fail2ban --enable-ufw --allow-port 443 2>&1)
status=$?

assert_status "exits 0" "0" "$status"

# The regression: these four lines used to be swallowed because the
# '>/dev/null' on the run() call site also ate the '(dry-run)' output.
assert_contains "shows the SSH allow rule"     "(dry-run) ufw allow 22/tcp"          "$out"
assert_contains "shows the --allow-port rule"  "(dry-run) ufw allow 443/tcp"         "$out"
assert_contains "shows default deny incoming"  "(dry-run) ufw default deny incoming" "$out"
assert_contains "shows default allow outgoing" "(dry-run) ufw default allow outgoing" "$out"
assert_contains "shows the enable step"        "would run: ufw --force enable"       "$out"

# fail2ban section still reports what it would write
assert_contains "shows the fail2ban files"     "would write"                          "$out"
assert_contains "reads the real sshd port"     "monitored port(s): 22"                "$out"

# Nothing was actually written
for f in /etc/fail2ban/jail.local /etc/fail2ban/fail2ban.local; do
    [[ -e "$f" ]] && created="yes" || created="no"
    assert_eq "dry-run did not create $f" "no" "$created"
done

summary
