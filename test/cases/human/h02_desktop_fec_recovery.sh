#!/usr/bin/env bash
# h02: FEC recovery under real packet loss, against the real desktop GUI.
#
# This is the one claim the auto tier cannot make: analyze.py recomputes the XOR
# parity and proves it is correct, but only the desktop's jitter buffer actually
# uses it to rebuild a dropped packet. Injecting loss needs a firewall rule on this
# machine, so the script prints the commands and waits — it never runs sudo itself.
set -euo pipefail
. "$(dirname "$0")/../../lib/env.sh"
. "$(dirname "$0")/../../lib/device.sh"
. "$(dirname "$0")/../../lib/settings.sh"
. "$(dirname "$0")/../../lib/human.sh"

GUI_TCP_PORT="${GUI_TCP_PORT:-8554}"
GUI_UDP_PORT="$((GUI_TCP_PORT + 1))"
LOSS_PROBABILITY="${LOSS_PROBABILITY:-0.05}"
HUMAN_SESSION_SECONDS="${HUMAN_SESSION_SECONDS:-30}"

RULE="INPUT -p udp --dport $GUI_UDP_PORT -m statistic --mode random --probability $LOSS_PROBABILITY -j DROP"

h_require_tty
d_require_device
d_wake
[ -n "$(d_pid)" ] || d_launch >/dev/null

h_observe "prepare" "
  1. desktop: MicYou GUI listening on $DESKTOP_IP:$GUI_TCP_PORT, receiver open so the
     audio is audible (headphones or a recorder)
  2. open a SECOND terminal and keep it ready — it needs root for the loss rule
  3. phone: unlocked, on the MicYou home screen
"
h_wait "ready"

apply_profile opus "48 kHz" mono "16-bit"
d_set_target "$DESKTOP_IP" "$GUI_TCP_PORT"

d_tap_fab
sleep 3
phase="$(d_phase)"
case "$phase" in
  *失败*|*Failed*) fail "phone did not reach Streaming (phase: $phase)" ;;
esac
h_step "baseline: ${HUMAN_SESSION_SECONDS}s with no loss injected"
sleep "$HUMAN_SESSION_SECONDS"

h_observe "inject loss — run these in the other terminal" "
  ADD (drops roughly probability $LOSS_PROBABILITY of the audio datagrams on the
  GUI's UDP port):

      sudo iptables -I $RULE

  REMOVE again straight after this case, whatever the result:

      sudo iptables -D $RULE

  This only touches incoming UDP on port $GUI_UDP_PORT while the rule is installed; it
  does not affect TCP control, mDNS, or any other traffic. 5% keeps the expected
  number of losses per 12-packet FEC group below one, which is what the parity can
  rebuild. Push it higher (0.1) if you want to hear the limit: multi-loss groups are
  unrecoverable by design, so audible gaps at 10% are expected, not a defect.
"
h_wait "rule installed"

h_step "lossy run: ${HUMAN_SESSION_SECONDS}s — keep talking, and note the loss counter in the GUI"
sleep "$HUMAN_SESSION_SECONDS"

h_observe "compare" "
  1. with 5% injected loss the GUI should report packet loss near 5% while the audio
     stays continuous: the jitter buffer rebuilds the dropped packets from the parity
     that follows each group of 12
  2. the recoverable losses must NOT arrive as clicks or dropouts — that is the whole
     point of the parity packet
  3. the control connection stays up through it (no '连接失败', the pong path is TCP)
  4. if you raised it to 10%, note the point where gaps begin: unrecovered multi-loss
     groups are expected there
"

d_tap_fab
h_wait "sudo iptables -D removed the rule — confirm it is gone (sudo iptables -S | grep $GUI_UDP_PORT shows nothing)"

h_verdict "FEC hid the injected losses at $LOSS_PROBABILITY"
log "h02 done (verdict in $HUMAN_LOG)"
