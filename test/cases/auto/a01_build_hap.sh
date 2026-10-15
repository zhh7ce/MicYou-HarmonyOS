#!/usr/bin/env bash
# a01: the native build still produces the encoder and packs it into a signed HAP.
# Covers the plan's "构建链" step: submodule initialized, assembleHap green, arm64
# libraries present at the sizes AGENTS.md quotes.
set -euo pipefail
. "$(dirname "$0")/../../lib/env.sh"
. "$(dirname "$0")/../../lib/device.sh"

d_require_device

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  ( cd "$REPO_ROOT" && hvigorw assembleHap --no-daemon ) >"$CASE_DIR/build.log" 2>&1 ||
    fail "assembleHap failed (see $CASE_DIR/build.log)"
fi
[ -f "$HAP" ] || fail "no HAP at $HAP"

git -C "$REPO_ROOT" submodule status lib/opus | grep -q '^ ' ||
  fail "lib/opus submodule not initialized — run git submodule update --init"

"$PY" - "$HAP" <<'PY' || exit 1
import re, sys, zipfile
want = {"libmcyopus.so": 594_568, "libc++_shared.so": 1_262_504}
names = {}
with zipfile.ZipFile(sys.argv[1]) as zf:
    for info in zf.infolist():
        if info.filename.startswith("libs/arm64-v8a/"):
            names[info.filename.rsplit("/", 1)[-1]] = info.file_size
missing = [n for n in want if n not in names]
if missing:
    print("FAIL libs/arm64-v8a is missing %s" % ", ".join(missing))
    sys.exit(1)
for name, size in sorted(want.items()):
    actual = names[name]
    drift = abs(actual - size) / size
    ok = drift <= 0.05
    print("%s %s: %d B (AGENTS.md quotes %d B, drift %.1f%%)" % (
        "PASS" if ok else "FAIL", name, actual, size, drift * 100))
    if not ok:
        sys.exit(1)
print("note hap total: %d B" % __import__("os").path.getsize(sys.argv[1]))
PY
log "a01 ok"
