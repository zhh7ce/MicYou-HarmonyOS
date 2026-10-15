#!/usr/bin/env bash
# a04: Opus at a non-48k native rate; the wire header must declare 16000 and the desktop's decoder choice stays valid.
set -euo pipefail
. "$(dirname "$0")/../../lib/env.sh"
. "$(dirname "$0")/../../lib/device.sh"
. "$(dirname "$0")/../../lib/settings.sh"

d_ready
apply_profile opus "16 kHz" mono "16-bit"
run_session "$CASE_DIR" "$SESSION_SECONDS"
$PY "$TEST_LIB_DIR/analyze.py" --in "$CASE_DIR/capture.jsonl" --profile opus-16k-mono
log "a04_opus_16k_mono.sh ok"
