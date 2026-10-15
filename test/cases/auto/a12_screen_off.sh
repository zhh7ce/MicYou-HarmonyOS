#!/usr/bin/env bash
# a12 (disruptive): the audioRecording continuous task has never been tested with
# the screen off — this closes that known gap or records what breaks. It suspends
# the display through power-shell, so put the phone somewhere it will not be needed:
# test/run.sh --auto --allow-disruptive
set -euo pipefail
. "$(dirname "$0")/../../lib/env.sh"
. "$(dirname "$0")/../../lib/device.sh"
. "$(dirname "$0")/../../lib/settings.sh"

SCREEN_OFF_SECONDS="${SCREEN_OFF_SECONDS:-60}"

d_ready
apply_profile opus "48 kHz" mono "16-bit"

d_hilog_clear
rx_start "$CASE_DIR" "$((SCREEN_OFF_SECONDS + 30))"
d_tap_fab
rx_wait_connect 12 || { d_hilog "$CASE_DIR/app.log" "$(d_pid)"; fail "session never started"; }
sleep 5
"$PY" - "$RX_JSONL" <<'PY' || fail "counting before suspend"
import json, sys
n = sum(1 for line in open(sys.argv[1]) if '"kind": "audio"' in line)
print("note pre-suspend audio packets: %d" % n)
sys.exit(0 if n > 100 else 1)
PY

log "suspending the display for ${SCREEN_OFF_SECONDS}s"
d_shell "power-shell suspend"
sleep "$SCREEN_OFF_SECONDS"
d_wake
packets_after="$(grep -c '"kind": "audio"' "$RX_JSONL")"
d_tap_fab
rx_stop
d_hilog "$CASE_DIR/app.log" "$(d_pid)"

$PY - "$RX_JSONL" "$SCREEN_OFF_SECONDS" "$packets_after" <<'PY' || exit 1
import json, sys
src, seconds, after = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
data = parity = 0
first_t = last_t = None
for line in open(src):
    event = json.loads(line)
    if event.get("kind") != "audio":
        continue
    first_t = event["t"] if first_t is None else first_t
    last_t = event["t"]
    if event["fec"]:
        parity += 1
    else:
        data += 1
span = last_t - first_t
print("total data %d, parity %d over %.1f s (%.1f pkt/s)" % (data, parity, span, data / span))
# 50 packets/s expected; two thirds tolerates the suspend/wake ramp.
if data / span < 33:
    print("FAIL the stream stalled while the screen was off (%.1f pkt/s)" % (data / span))
    sys.exit(1)
print("PASS the continuous task held the stream up with the screen off")
PY
log "a12 ok — AGENTS.md known-gaps line about the screen-off case can go"
