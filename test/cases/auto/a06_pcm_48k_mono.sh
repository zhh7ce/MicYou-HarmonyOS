#!/usr/bin/env bash
# a06: PCM regression on the profile the client shipped with before Opus.
set -euo pipefail
. "$(dirname "$0")/../../lib/env.sh"
. "$(dirname "$0")/../../lib/device.sh"
. "$(dirname "$0")/../../lib/settings.sh"

d_ready
apply_profile pcm "48 kHz" mono "16-bit"
run_session "$CASE_DIR" "$SESSION_SECONDS"
$PY "$TEST_LIB_DIR/analyze.py" --in "$CASE_DIR/capture.jsonl" --profile pcm-48k-mono
log "a06_pcm_48k_mono.sh ok"
