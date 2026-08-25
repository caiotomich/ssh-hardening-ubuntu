# Minimal assert helpers. No framework on purpose: the repository ships four
# files and a bats dependency would outweigh the suite it runs.

SCRIPT="${SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/../ssh-hardening.sh}"
export SCRIPT

PASS=0
FAIL=0

_green() { printf '\033[0;32m%s\033[0m' "$1"; }
_red()   { printf '\033[0;31m%s\033[0m' "$1"; }

assert_eq() {   # assert_eq <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        printf '  %s %s\n' "$(_green ok)" "$1"
        PASS=$(( PASS + 1 ))
    else
        printf '  %s %s\n      expected: %q\n      actual:   %q\n' \
            "$(_red FAIL)" "$1" "$2" "$3"
        FAIL=$(( FAIL + 1 ))
    fi
}

# Strips ANSI colour codes: the script wraps '(dry-run)' in them, so a plain
# substring match against the raw output never lines up.
strip_ansi() { sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g'; }

assert_contains() {   # assert_contains <label> <needle> <haystack>
    local hay; hay=$(strip_ansi <<<"$3")
    if [[ "$hay" == *"$2"* ]]; then
        printf '  %s %s\n' "$(_green ok)" "$1"
        PASS=$(( PASS + 1 ))
    else
        printf '  %s %s\n      missing: %q\n      in:      %q\n' \
            "$(_red FAIL)" "$1" "$2" "$hay"
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_status() {   # assert_status <label> <expected> <actual>
    assert_eq "$1" "$2" "$3"
}

summary() {
    printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
    (( FAIL == 0 ))
}

# Source the script for its functions only, without running anything.
# Always inside a subshell: the script marks several variables readonly.
lib_source() {
    SSH_HARDENING_SOURCE_ONLY=1
    export SSH_HARDENING_SOURCE_ONLY
    # shellcheck disable=SC1090
    source "$SCRIPT"
}
