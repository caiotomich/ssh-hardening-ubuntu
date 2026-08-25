#!/usr/bin/env bash
# Authorized-key detection, and the errexit regression it used to hide.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "key detection"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mk_home() {   # mk_home <name> <line>...
    local name="$1"; shift
    mkdir -p "$TMP/$name/.ssh"
    printf '%s\n' "$@" > "$TMP/$name/.ssh/authorized_keys"
}

mk_home alice 'ssh-ed25519 AAAAC3Nza alice@laptop'
mk_home bob   'ssh-rsa AAAAB3Nza bob@desk' 'ecdsa-sha2-nistp256 AAAAE2 bob@phone'
mk_home carol '# just a comment'
mkdir -p "$TMP/dave/.ssh" && : > "$TMP/dave/.ssh/authorized_keys"   # empty file

# ---- scan_authorized_keys ----
run_scan() {
    (
        lib_source
        set +e
        scan_authorized_keys < <(printf '%s\n' "$@")
        printf '%s|%s' "$total_keys" "${users_with_keys[*]:-}"
    )
}

out=$(run_scan "$TMP/alice")
assert_eq "one key"        "1|alice (1 key(s))" "$out"

out=$(run_scan "$TMP/bob")
assert_eq "two keys"       "2|bob (2 key(s))"   "$out"

out=$(run_scan "$TMP/carol")
assert_eq "comment only"   "0|"                 "$out"

out=$(run_scan "$TMP/dave")
assert_eq "empty file"     "0|"                 "$out"

out=$(run_scan "$TMP/nonexistent")
assert_eq "missing home"   "0|"                 "$out"

out=$(run_scan "$TMP/alice" "$TMP/bob" "$TMP/carol")
assert_eq "sum across homes" "3|alice (1 key(s)) bob (2 key(s))" "$out"

# Known gap, fixed in PR 4: a key preceded by options is not counted.
mk_home eve 'from="10.0.0.1" ssh-ed25519 AAAAC3Nza eve@ops'
out=$(run_scan "$TMP/eve")
assert_eq "KNOWN GAP: key with options prefix is missed" "0|" "$out"

# ---- scan_central_authorized_keys: the errexit regression ----
# Reproduces the exact shape that killed the script: no key in any home, so
# total_keys is 0 when the central file is counted. With (( total_keys++ ))
# the arithmetic evaluates to the OLD value (0), the status is 1, and errexit
# aborted the run with no message at all.
mkdir -p "$TMP/bin" "$TMP/etc"
printf 'ssh-ed25519 AAAAC3Nza central@key\n' > "$TMP/etc/all_keys"
cat > "$TMP/bin/sshd" <<EOF
#!/bin/sh
echo "authorizedkeysfile $TMP/etc/all_keys"
EOF
chmod +x "$TMP/bin/sshd"

out=$(
    PATH="$TMP/bin:$PATH"
    (
        lib_source
        users_with_keys=()
        total_keys=0
        scan_central_authorized_keys          # must NOT abort under errexit
        printf '%s|%s' "$total_keys" "${users_with_keys[*]:-}"
    )
)
status=$?
assert_status  "central file: does not abort under errexit" "0" "$status"
assert_contains "central file: counted"      "1|"           "$out"
assert_contains "central file: labelled"     "(central file)" "$out"

# Guard documenting *why* the fix is what it is, so nobody reverts it.
( set -e; x=0; (( x++ )) ; ) 2>/dev/null
assert_status "(( x++ )) with x=0 returns non-zero (reason for the fix)" "1" "$?"
( set -e; x=0; x=$(( x + 1 )); )
assert_status "x=\$(( x + 1 )) always returns 0"                          "0" "$?"

summary
