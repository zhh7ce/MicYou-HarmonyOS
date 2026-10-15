#!/usr/bin/env bash
# a10: when the server stops pinging, the watchdog has to fail the session and the
# teardown has to destroy the native encoder — the spec's error-handling path.
set -euo pipefail
. "$(dirname "$0")/../../lib/env.sh"
. "$(dirname "$0")/../../lib/device.sh"
. "$(dirname "$0")/../../lib/settings.sh"

d_ready
apply_profile opus "48 kHz" mono "16-bit"

# Pings stop after 10 s, the session window is 25 s: HEARTBEAT_TIMEOUT_MS is 5000,
# so the failure has to land in between without anyone touching the phone.
NO_STOP=1 run_session "$CASE_DIR" 25 --stop-ping-after 10

log "phase now: $(d_phase)"
grep -E "heartbeat|stale" "$CASE_DIR/app.log" | tail -3
grep -q "destroyEncoder" "$CASE_DIR/app.log" ||
  fail "no destroyEncoder in the teardown log (see $CASE_DIR/app.log)"
grep -qE "pump.*stop|capturer" "$CASE_DIR/app.log" ||
  log "note: no pump stop line — read $CASE_DIR/app.log for the teardown order"
log "a10 ok"
