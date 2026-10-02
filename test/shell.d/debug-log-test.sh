#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Both helpers publish to a fixed name in world-writable /tmp, so the test has to
# exercise those exact names. Anything already there is moved aside first and put
# back on the way out.
log=/tmp/omarchy-debug.log
legacy_upload=/tmp/upload-log.txt
legacy_system_info=/tmp/system-info.txt
tmp=$(mktemp -d)
saved_log=""
had_saved_log=false

cleanup() {
  rm -f "$log" "$legacy_upload" "$legacy_system_info"
  rm -f /tmp/omarchy-debug.* /tmp/omarchy-upload-log.* /tmp/omarchy-system-info.* 2>/dev/null || true
  if $had_saved_log; then
    mv -f "$saved_log" "$log"
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

if [[ -e $log || -L $log ]]; then
  saved_log="$tmp/saved-omarchy-debug.log"
  mv -f "$log" "$saved_log"
  had_saved_log=true
fi

# Stubs keep the collection cheap and offline: no sudo, no network, and nothing
# that depends on what this machine happens to have installed.
mkdir -p "$tmp/bin"
for tool in inxi journalctl expac pacman fastfetch curl date hostname; do
  cat >"$tmp/bin/$tool" <<EOF
#!/bin/bash
echo "[stub $tool]"
EOF
  chmod +x "$tmp/bin/$tool"
done
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/bash
echo "https://logs.omarchy.org/stub"
EOF
chmod +x "$tmp/bin/curl"

canary="$tmp/canary"
printf 'untouched\n' >"$canary"

# --- omarchy-debug -------------------------------------------------------

rm -f "$log"
ln -s "$canary" "$log"

PATH="$tmp/bin:$ROOT/bin:$PATH" "$ROOT/bin/omarchy-debug" --no-sudo --print >"$tmp/printed" 2>/dev/null || true

[[ $(cat "$canary") == untouched ]] ||
  fail "omarchy debug does not write through a symlink another local process planted" \
    "canary now reads: $(cat "$canary")"
pass "omarchy debug does not write through a planted symlink"

if [[ -L $log ]]; then
  fail "omarchy debug replaces a planted symlink instead of following it"
fi
[[ -f $log ]] || fail "omarchy debug publishes the log"
pass "omarchy debug replaces a planted symlink with the log"

grep -q 'SYSTEM INFORMATION' "$log" ||
  fail "the published log carries the collected diagnostics" "$(head -5 "$log")"
pass "the published log carries the collected diagnostics"

grep -q 'SYSTEM INFORMATION' "$tmp/printed" ||
  fail "--print still emits the log" "$(cat "$tmp/printed")"
pass "--print still emits the log"

mode=$(stat -c '%a' "$log" 2>/dev/null || true)
if [[ -n $mode ]]; then
  if (( 8#$mode & 077 )); then
    fail "the published log is owner-only" "mode: $mode"
  fi
  pass "the published log is owner-only"
else
  skip "the filesystem does not report modes; cannot check the log's permissions"
fi

leftovers=$(compgen -G '/tmp/omarchy-debug.????????' || true)
[[ -z $leftovers ]] || fail "omarchy debug leaves no staging file behind" "$leftovers"
pass "omarchy debug leaves no staging file behind"

# --- omarchy-upload-log --------------------------------------------------

rm -f "$legacy_upload" "$legacy_system_info"
printf 'upload canary\n' >"$tmp/upload-canary"
ln -s "$tmp/upload-canary" "$legacy_upload"
ln -s "$tmp/upload-canary" "$legacy_system_info"

upload_out=$(PATH="$tmp/bin:$ROOT/bin:$PATH" "$ROOT/bin/omarchy-upload-log" installed 2>&1 || true)

[[ $(cat "$tmp/upload-canary") == "upload canary" ]] ||
  fail "omarchy upload-log does not write through the symlinks it used to own" \
    "canary now reads: $(cat "$tmp/upload-canary")"
pass "omarchy upload-log leaves its old fixed names alone"

if [[ ! -L $legacy_upload || ! -L $legacy_system_info ]]; then
  fail "omarchy upload-log no longer writes to the legacy fixed paths" \
    "$legacy_upload: $(stat -c '%F' "$legacy_upload" 2>/dev/null || echo missing)
$legacy_system_info: $(stat -c '%F' "$legacy_system_info" 2>/dev/null || echo missing)"
fi
pass "omarchy upload-log collects into private temporary files"

upload_leftovers=$(compgen -G '/tmp/omarchy-upload-log.????????' || true)$(compgen -G '/tmp/omarchy-system-info.????????' || true)
[[ -z $upload_leftovers ]] ||
  fail "omarchy upload-log removes its temporary files" "$upload_leftovers"
pass "omarchy upload-log removes its temporary files"

grep -q 'https://logs.omarchy.org/stub' <<<"$upload_out" ||
  fail "omarchy upload-log still uploads and reports the URL" "$upload_out"
pass "omarchy upload-log still uploads and reports the URL"