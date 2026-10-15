#!/usr/bin/env bash
# a03: Opus 48 kHz / mono / 16-bit end to end: 50 pkt/s, one XOR parity per 12, libopus decodes the whole stream.
set -euo pipefail
. "$(dirname "$0")/../../lib/env.sh"
. "$(dirname "$0")/../../lib/device.sh"
. "$(dirname "$0")/../../lib/settings.sh"

d_ready
apply_profile opus "48 kHz" mono "16-bit"
run_session "$CASE_DIR" "$SESSION_SECONDS"
$PY "$TEST_LIB_DIR/analyze.py" --in "$CASE_DIR/capture.jsonl" --profile opus-48k-mono
log "a03_opus_48k_mono.sh ok"
