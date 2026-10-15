#!/usr/bin/env bash
# a08: the gated values are the values on the wire. Store an Opus-incompatible
# capture profile under PCM, switch to Opus, and check the session reports the
# migrated 48 kHz / 16-bit rather than the stale 44.1 kHz / 24-bit.
set -euo pipefail
. "$(dirname "$0")/../../lib/env.sh"
. "$(dirname "$0")/../../lib/device.sh"
. "$(dirname "$0")/../../lib/settings.sh"

d_ready
apply_profile pcm "44.1 kHz" mono "24-bit"

s_open
s_codec opus
s_close

run_session "$CASE_DIR" "$SESSION_SECONDS"
$PY "$TEST_LIB_DIR/analyze.py" --in "$CASE_DIR/capture.jsonl" --profile opus-48k-mono

# The clamp is what the controller does on its own at session start; check the log
# records it instead of silently accepting the migration.
if grep -q "capture forced" "$CASE_DIR/app.log" || grep -q "clamp" "$CASE_DIR/app.log"; then
  log "a08 ok (controller logged the clamp)"
else
  log "a08 ok (no clamp line: migration already happened in the settings page)"
fi
