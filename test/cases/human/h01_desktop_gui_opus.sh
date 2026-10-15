#!/usr/bin/env bash
# h01: one Opus session against the real desktop GUI.
# The auto tier proves the packets are wire-valid; only the GUI's own counters and
# an ear prove the stream decodes, sounds right and survives the DSP chain.
set -euo pipefail
. "$(dirname "$0")/../../lib/env.sh"
. "$(dirname "$0")/../../lib/device.sh"
. "$(dirname "$0")/../../lib/settings.sh"
. "$(dirname "$0")/../../lib/human.sh"

GUI_TCP_PORT="${GUI_TCP_PORT:-8554}"
HUMAN_SESSION_SECONDS="${HUMAN_SESSION_SECONDS:-$SESSION_SECONDS}"

h_require_tty
d_require_device
d_wake
[ -n "$(d_pid)" ] || d_launch >/dev/null

h_observe "prepare" "
  1. desktop: start the MicYou GUI and confirm it is listening on $DESKTOP_IP:$GUI_TCP_PORT
  2. make sure the fake-desktop receiver from the auto tier is NOT running (it owns
     port $TEST_TCP_PORT/$TEST_UDP_PORT, and the GUI's audio port is $((GUI_TCP_PORT + 1)))
  3. phone: unlocked, on the MicYou home screen
"
h_wait "ready"

apply_profile opus "48 kHz" mono "16-bit"
d_set_target "$DESKTOP_IP" "$GUI_TCP_PORT"
d_hilog_clear
d_tap_fab
sleep 3
phase="$(d_phase)"
case "$phase" in
  *失败*|*Failed*)
    d_hilog "$CASE_DIR/app.log" "$(d_pid)"
    fail "phone did not reach Streaming (phase: $phase, log: $CASE_DIR/app.log)"
    ;;
esac
h_step "session running for ${HUMAN_SESSION_SECONDS}s (phone phase: ${phase:-unknown}) — speak now"

sleep "$HUMAN_SESSION_SECONDS"
d_tap_fab

h_observe "GUI" "
  1. connection row shows the phone. Platform label reads 'MicYou HarmonyOS' only on
     2.1.1+; a released 2.1.0 build shows 'MicYou Mobile' — cosmetic, not a failure
  2. audio reaches the virtual mic: record 30 s in any app and listen back
     - speech is intelligible, no warbling, no robotic artifacts (a codec mismatch
       sounds like that immediately)
     - no periodic clicking every ~240 ms (that is a broken FEC group boundary)
  3. silence: stop talking for a few seconds. The phone keeps sending 1-byte DTX
     packets, so the desktop VAD should close the gate and the virtual mic should go
     quiet rather than hiss
  4. statistics: packet loss and jitter in the normal range (against the auto tier's
     numbers: loss 0 %, sub-millisecond jitter), and the server log shows no
     'invalid audio packet' line for this session
  5. stop the session from the phone, then the GUI drops the client cleanly
"
h_verdict "Opus audio plays correctly through the real GUI"
log "h01 done (verdict in $HUMAN_LOG)"
