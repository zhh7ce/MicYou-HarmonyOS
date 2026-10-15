# Sourced after device.sh. Settings-page navigation and audio-profile helpers.
#
# Chip labels under Audio: sample rate and bit depth are literal strings in
# SettingsView.ets (not localized); codec and channel labels come from string.json
# and therefore differ per app language, so they take an alternatives list.

S_RATES=("16 kHz" "44.1 kHz" "48 kHz" "96 kHz")
S_DEPTHS=("16-bit" "24-bit" "32-bit float")

s_open() { d_open_settings; }

s_close() {
  d_back
  d_dump
  if [ "$(q --text-contains "kHz" --out count)" != "0" ]; then
    d_back
  fi
}

s_codec() {
  case "$1" in
    opus) d_tap_label "Opus" ;;
    pcm) d_tap_label "PCM" ;;
    *) fail "unknown codec $1" ;;
  esac
}

s_rate() { d_tap_label "$1"; }

s_channels() {
  case "$1" in
    mono) d_tap_label "Mono" "单声道" "單聲道" ;;
    stereo) d_tap_label "Stereo" "双声道" "雙聲道" ;;
    *) fail "unknown channel mode $1" ;;
  esac
}

s_depth() { d_tap_label "$1"; }

s_auto_connect() {
  # The toggle sits on the row labelled Auto-connect / 自动连接; the Toggle widget
  # itself carries no text, so it is found as the nearest toggle to that label.
  d_dump
  local row center
  row="$(q --text-contains "Auto-connect" --out bounds 2>/dev/null ||
    q --text-contains "自动连接" --out bounds 2>/dev/null ||
    q --text-contains "自動連線" --out bounds 2>/dev/null)"
  [ -n "$row" ] || fail "auto-connect row not found on the settings page"
  center="$("$PY" - "$row" <<'PY'
import sys
digits = sys.argv[1].replace("][", ",").strip("[]").split(",")
left, top, right, bottom = (int(v) for v in digits)
print((left + right) // 2, (top + bottom) // 2 + 90)
PY
)"
  # shellcheck disable=SC2086
  d_tap $center "$TAP_SETTLE"
}

# apply_profile <codec> <rate-label> <mono|stereo> <bitdepth-label>
# PCM is selected first so every chip is live while the capture fields are set,
# then the target codec is applied last.
apply_profile() {
  local codec="$1" rate="$2" channels="$3" depth="$4"
  s_open
  s_codec pcm
  s_rate "$rate"
  s_channels "$channels"
  s_depth "$depth"
  if [ "$codec" != "pcm" ]; then
    s_codec "$codec"
  fi
  s_close
}
