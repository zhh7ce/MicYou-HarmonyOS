#!/usr/bin/env bash
# a02: Opus greys out the capture chips it cannot encode, and the grey state
# appears without leaving the page. The behaviour side of the same rule (a greyed
# chip cannot change the wire header) is a08.
set -euo pipefail
. "$(dirname "$0")/../../lib/env.sh"
. "$(dirname "$0")/../../lib/device.sh"
. "$(dirname "$0")/../../lib/settings.sh"

d_ready

# Start from a known PCM profile so every chip is live and the lock is visible.
apply_profile pcm "44.1 kHz" mono "24-bit"

s_open
s_codec opus

locked=()
live=()
for label in "44.1 kHz" "96 kHz" "24-bit" "32-bit float"; do
  opacity="$(d_chip_attr opacity "$label")"
  if [ "$opacity" = "0.5" ]; then locked+=("$label"); else
    fail "$label should be greyed under Opus, opacity=$opacity"
  fi
done
for label in "16 kHz" "48 kHz" "16-bit"; do
  opacity="$(d_chip_attr opacity "$label")"
  if [ "$opacity" = "1" ]; then live+=("$label"); else
    fail "$label must stay selectable under Opus, opacity=$opacity"
  fi
done
log "greyed: ${locked[*]} | live: ${live[*]}"

# The migration that Task 7 added has to be visible immediately: 44.1 kHz/24-bit
# stored under PCM becomes 48 kHz/16-bit the moment Opus is picked.
d_assert_selected "48 kHz" "${S_RATES[@]}"
d_assert_selected "16-bit" "${S_DEPTHS[@]}"
s_close

# Persisted: leaving and re-entering the page must show the same choice.
s_open
d_assert_selected "Opus" "Opus" "PCM"
s_codec pcm
for label in "44.1 kHz" "96 kHz" "24-bit" "32-bit float"; do
  opacity="$(d_chip_attr opacity "$label")"
  [ "$opacity" = "1" ] || fail "$label still greyed after switching back to PCM"
done
s_close
log "a02 ok"
