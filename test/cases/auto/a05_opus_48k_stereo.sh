#!/usr/bin/env bash
# a05: Opus stereo; the 20 ms frame is 3840 B in, and parity groups still close every 12 packets.
set -euo pipefail
. "$(dirname "$0")/../../lib/env.sh"
. "$(dirname "$0")/../../lib/device.sh"
. "$(dirname "$0")/../../lib/settings.sh"

d_ready
apply_profile opus "48 kHz" stereo "16-bit"
run_session "$CASE_DIR" "$SESSION_SECONDS"
$PY "$TEST_LIB_DIR/analyze.py" --in "$CASE_DIR/capture.jsonl" --profile opus-48k-stereo
log "a05_opus_48k_stereo.sh ok"
