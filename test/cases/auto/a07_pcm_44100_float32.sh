#!/usr/bin/env bash
# a07: PCM on a rate and format Opus cannot encode, proving the Opus path stays out of the way.
set -euo pipefail
. "$(dirname "$0")/../../lib/env.sh"
. "$(dirname "$0")/../../lib/device.sh"
. "$(dirname "$0")/../../lib/settings.sh"

d_ready
apply_profile pcm "44.1 kHz" mono "32-bit float"
run_session "$CASE_DIR" "$SESSION_SECONDS"
$PY "$TEST_LIB_DIR/analyze.py" --in "$CASE_DIR/capture.jsonl" --profile pcm-44100-float32
log "a07_pcm_44100_float32.sh ok"
