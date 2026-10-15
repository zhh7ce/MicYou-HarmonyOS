#!/usr/bin/env bash
# a11 (disruptive): kill the app and let auto-connect rebuild an Opus session on
# its own, so a stored profile survives a process restart with the same wire
# header. Force-stops the app and flips the auto-connect toggle — run it when the
# phone is yours: test/run.sh --auto --allow-disruptive
set -euo pipefail
. "$(dirname "$0")/../../lib/env.sh"
. "$(dirname "$0")/../../lib/device.sh"
. "$(dirname "$0")/../../lib/settings.sh"

d_ready
apply_profile opus "48 kHz" mono "16-bit"

# One normal session first: recordSuccess only stores the last server on a real
# success, and auto-connect refuses to run without one.
run_session "$CASE_DIR/prewarm" 12
$PY "$TEST_LIB_DIR/analyze.py" --in "$CASE_DIR/prewarm/capture.jsonl" --profile opus-48k-mono \
  --min-packets 40

s_open
s_auto_connect
s_close

rx_start "$CASE_DIR" 25
d_restart
if ! rx_wait_connect 20; then
  d_hilog "$CASE_DIR/app.log" "$(d_pid)"
  rx_stop
  fail "auto-connect did not reach the receiver after a relaunch (see $CASE_DIR)"
fi
d_hilog "$CASE_DIR/app.log" "$(d_pid)"
while kill -0 "$RX_PID" 2>/dev/null; do sleep 1; done

$PY "$TEST_LIB_DIR/analyze.py" --in "$CASE_DIR/capture.jsonl" --profile opus-48k-mono --min-packets 40

# Leave the phone as it was found.
s_open
s_auto_connect
s_close
log "a11 ok"
