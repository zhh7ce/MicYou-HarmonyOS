#!/usr/bin/env bash
# a09: mute in the middle of a session must not break the FEC arithmetic. The
# phone keeps streaming while muted (mute only tells the desktop), so parity
# groups have to close on schedule across both transitions.
set -euo pipefail
. "$(dirname "$0")/../../lib/env.sh"
. "$(dirname "$0")/../../lib/device.sh"
. "$(dirname "$0")/../../lib/settings.sh"

d_ready
apply_profile opus "48 kHz" mono "16-bit"

MUTE_AFTER=8 run_session "$CASE_DIR" "$SESSION_SECONDS"
$PY "$TEST_LIB_DIR/analyze.py" --in "$CASE_DIR/capture.jsonl" --profile opus-48k-mono

grep -q "sendMute\|mute" "$CASE_DIR/app.log" ||
  log "note: no mute line in app.log — check the tap landed (the pill is at the bottom left)"
log "a09 ok"
