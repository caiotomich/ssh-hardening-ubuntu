#!/usr/bin/env bash
# Runs every test_*.sh next to this file. Exit 1 if any of them fails.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

failed=0
for t in test_*.sh; do
    printf '\n=== %s ===\n' "$t"
    if bash "$t"; then :; else failed=$(( failed + 1 )); fi
done

printf '\n'
if (( failed )); then
    printf '\033[0;31m%d test file(s) failed\033[0m\n' "$failed"
    exit 1
fi
printf '\033[0;32mall test files passed\033[0m\n'
