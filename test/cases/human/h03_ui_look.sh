#!/usr/bin/env bash
# h03: how the gated settings page looks and reads.
# a02 proves the disabled chips carry opacity=0.5 in the widget tree; whether that
# still looks like a deliberate "not available" rather than a broken control, and
# whether the Chinese hint explains the restriction, is a judgement call.
set -euo pipefail
. "$(dirname "$0")/../../lib/env.sh"
. "$(dirname "$0")/../../lib/device.sh"
. "$(dirname "$0")/../../lib/settings.sh"
. "$(dirname "$0")/../../lib/human.sh"

h_require_tty
d_require_device
d_wake
d_ready

# Leave the phone in the state worth looking at: PCM first at an Opus-incompatible
# profile, so switching to Opus visibly greys and re-selects chips.
apply_profile pcm "44.1 kHz" mono "24-bit"
s_open
s_codec opus
d_dump
cp "$LAYOUT" "$CASE_DIR/settings-opus.json"
h_step "layout snapshot for reference: $CASE_DIR/settings-opus.json"

h_observe "settings page, Audio section, Opus selected" "
  1. the greyed chips (44.1 kHz, 96 kHz, 24-bit, 32-bit float): do they read as
     'not available for this codec'? At 50% opacity they must stay legible, and the
     selected one must not be the greyed one
  2. the selection ring moved on its own to 48 kHz / 16-bit the moment Opus was
     tapped — is that obvious enough, or does it need a visible cue
  3. the hint under the codec row reads:
       Opus 以 20 毫秒 VOIP 帧编码并附带 FEC，采样率与位深会限制到兼容组合。
     Does that explain what just happened on screen?
  4. tap a greyed chip: it must be inert, with no state change and no jump of the
     selection
  5. scroll the whole page: theme/language rows, connection history, About — nothing
     clipped, no string cut off at the card edge
  6. switch the app theme (Appearance) and re-read the same row: the grey chips must
     still be distinguishable in dark mode
"
h_verdict "the greyed state and the hint read correctly on screen"

# Restore a plain PCM profile so the next case starts from stock settings.
s_codec pcm
s_rate "48 kHz"
s_depth "16-bit"
s_close
log "h03 done (verdict in $HUMAN_LOG)"
