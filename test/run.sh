#!/usr/bin/env bash
# Run every test/test_*.vim in a fresh headless Vim. Usage: test/run.sh [file...]
set -u
cd "$(dirname "$0")/.."
files=("$@")
[ ${#files[@]} -eq 0 ] && files=(test/test_*.vim)
status=0
TIMEOUT=""; command -v timeout >/dev/null && TIMEOUT="timeout 120"
for f in "${files[@]}"; do
  out=$(mktemp)
  TEST_OUT="$out" $TIMEOUT vim -Nu NONE -i NONE -n -es -S test/runner.vim "$f" </dev/null >/dev/null 2>&1
  code=$?
  echo "== $f"
  if [ -s "$out" ]; then cat "$out"; else echo "    (no output, vim exited $code)"; fi
  [ $code -ne 0 ] && status=1
  rm -f "$out"
done
exit $status
