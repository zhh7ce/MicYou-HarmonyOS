# Sourced after env.sh. Everything that touches the phone goes through here.
#
# Taps are located by querying the widget tree (uitest dumpLayout), never by
# hardcoded coordinates: chips carry their label as text, and the buttons on the
# home screen are told apart by geometry (gear at the top, the FAB by area, the
# mute pill at the bottom left).

DUMP_SEQ=0
LAYOUT=""

d_shell() { "$HDC" shell "$@" 2>&1 | tr -d '\r'; }

d_require_device() {
  local targets
  targets="$("$HDC" list targets | tr -d '\r')"
  if [ "$targets" = "[Empty]" ] || [ -z "$targets" ]; then
    fail "no device on hdc (list targets: $targets) — replug the phone"
  fi
}

d_wake() {
  d_shell "power-shell wakeup" >/dev/null 2>&1
  d_shell "uitest uiInput keyEvent Home" >/dev/null 2>&1
  sleep 0.4
}

d_pid() { d_shell "pidof $BUNDLE"; }

d_launch() {
  d_shell "aa start -b $BUNDLE -a $ABILITY" >/dev/null
  sleep 1.5
  local pid
  pid="$(d_pid)"
  [ -n "$pid" ] || fail "app did not come up (bundle $BUNDLE)"
  echo "$pid"
}

d_restart() {
  d_shell "aa force-stop $BUNDLE" >/dev/null
  sleep 0.8
  d_launch
}

d_install() {
  [ -f "$HAP" ] || fail "HAP missing at $HAP — run case a01 or hvigorw assembleHap first"
  local out
  out="$("$HDC" install -r "$HAP" 2>&1 | tr -d '\r')"
  case "$out" in
    *successfully*) log "installed: $out" ;;
    *) fail "install failed: $out" ;;
  esac
}

d_dump() {
  DUMP_SEQ=$((DUMP_SEQ + 1))
  local remote=/data/local/tmp/q"$DUMP_SEQ".json
  local local_file="$RESULTS_DIR/layout-$DUMP_SEQ.json"
  d_shell "uitest dumpLayout -p $remote" >/dev/null
  "$HDC" file recv "$remote" "$local_file" >/dev/null || fail "could not receive $remote"
  LAYOUT="$local_file"
}

# q <qlayout args...> — query the last dumped layout.
q() { "$PY" "$TEST_LIB_DIR/qlayout.py" "$LAYOUT" "$@"; }

q_or_die() {
  local out
  out="$(q "$@")" || fail "no widget matches: $*"
  echo "$out"
}

d_tap() { d_shell "uitest uiInput click $1 $2" >/dev/null; sleep "$3"; }
TAP_SETTLE="${TAP_SETTLE:-0.9}"

d_tap_text() {
  # $1 = widget type, $2 = exact text
  d_dump
  local center
  center="$(q_or_die --type "$1" --text "$2" --out center)"
  # shellcheck disable=SC2086
  d_tap $center "$TAP_SETTLE"
}

d_back() { d_shell "uitest uiInput keyEvent Back" >/dev/null; sleep "$TAP_SETTLE"; }

d_tap_label() {
  # $1 = chip label in the current app language, extra args = the same label in the
  # other locales the app ships. Labels are literal for rates and bit depths, and
  # come from string.json for codec and channel names.
  local label center
  for label in "$@"; do
    d_dump
    if center="$(q --type Text --text "$label" --out center 2>/dev/null)"; then
      # shellcheck disable=SC2086
      d_tap $center "$TAP_SETTLE"
      return 0
    fi
  done
  fail "no chip labelled: $*"
}

d_set_input() {
  # $1 = 0-based TextInput index, $2 = new value. uitest has no clear command, so
  # the field is focused, emptied with KEYCODE_DEL (2055) per existing character,
  # then re-typed.
  d_dump
  local center old len
  center="$(q_or_die --type TextInput --out center --nth "$1")"
  old="$(q --type TextInput --out text --nth "$1")"
  # shellcheck disable=SC2086
  d_tap $center 0.6
  for ((len = 0; len < ${#old}; len = len + 1)); do
    d_shell "uitest uiInput keyEvent 2055" >/dev/null
  done
  sleep 0.3
  d_shell "uitest uiInput text $2" >/dev/null
  sleep 0.4
  d_dump
  local now
  now="$(q --type TextInput --out text --nth "$1")"
  [ "$now" = "$2" ] || fail "input $1 shows '$now', expected '$2'"
}

d_open_settings() {
  d_dump
  local gear
  gear="$(q_or_die --type Button --clickable true --top-lt 420 --out center)"
  # shellcheck disable=SC2086
  d_tap $gear "$TAP_SETTLE"
  d_dump
  q --text-contains "kHz" --out count | grep -q '[1-9]' || fail "settings page did not open"
}

# Target override: the fake desktop is not mDNS-advertised, so the manual host and
# port fields steer the session. They take precedence over a discovered row.
d_set_target() {
  d_set_input 0 "$1"
  d_set_input 1 "$2"
}

d_tap_fab() {
  d_dump
  local fab
  fab="$(q_or_die --type Button --clickable true --min-area 60000 --out center)"
  # shellcheck disable=SC2086
  d_tap $fab 1.2
}

d_tap_mute() {
  d_dump
  local pill
  pill="$(q_or_die --type Button --clickable true --left-lt 400 --bottom-gt 2000 --out center)"
  # shellcheck disable=SC2086
  d_tap $pill "$TAP_SETTLE"
}

d_phase() {
  d_dump
  q --text-contains "推流" --out count >/dev/null
  q --out list --type Text | grep -Eo "(Idle|准备中|连接中|推流中|失败|Connecting|Streaming|Failed)" | head -1
}

d_chip_attr() {
  # $1 = layout attribute (opacity | backgroundColor | selected), $2 = chip label.
  d_dump
  q_or_die --type Text --text "$2" --out "$1"
}

# d_assert_selected <expected> <label> [<label>...]
# A SettingsView chip is a plain Text whose selection is carried only by its
# background colour (primary vs surface_container_high), so the chosen chip is the
# colour that appears once while every other chip repeats the same value.
d_assert_selected() {
  local expected="$1"
  shift
  d_dump
  local labels=("$@") colors=()
  local label color c picked=() majority="" best=0 count i
  for label in "${labels[@]}"; do
    if ! color="$(q --type Text --text "$label" --out backgroundColor 2>/dev/null)"; then
      fail "chip '$label' is not on the page ($LAYOUT)"
    fi
    colors+=("$color")
  done
  for c in "${colors[@]}"; do
    count=0
    for color in "${colors[@]}"; do
      if [ "$color" = "$c" ]; then
        count=$((count + 1))
      fi
    done
    if [ "$count" -gt "$best" ]; then
      best="$count"
      majority="$c"
    fi
  done
  for i in "${!labels[@]}"; do
    if [ "${colors[$i]}" != "$majority" ]; then
      picked+=("${labels[$i]}")
    fi
  done
  if [ "${#picked[@]}" -ne 1 ] || [ "${picked[0]}" != "$expected" ]; then
    fail "expected '$expected' to be the selected chip, got '${picked[*]:-none}' (colours: ${colors[*]:-none})"
  fi
}

d_hilog() {
  # $1 = destination file, $2 = pid. Filtered by pid because NETSTACK floods the
  # app buffer and eats domain/tag filters (see AGENTS.md, Debug loop). Call
  # d_hilog_clear at the start of the window you care about.
  "$HDC" shell "hilog -x -P $2" 2>&1 | tr -d '\r' | grep -E "A3307/$BUNDLE" >"$1"
}

d_hilog_clear() {
  d_shell "hilog -r" >/dev/null
  d_shell "hilog -Q pidoff" >/dev/null 2>&1
}

# rx_start <case-dir> <seconds> <receiver-extra-args...>
# Boots the fake desktop in the background; sets RX_PID.
rx_start() {
  RX_DIR="$1"; local seconds="$2"
  shift 2
  RX_JSONL="$RX_DIR/capture.jsonl"
  "$PY" "$TEST_LIB_DIR/receiver.py" --tcp-port "$TEST_TCP_PORT" --udp-port "$TEST_UDP_PORT" \
    --duration "$seconds" --out "$RX_JSONL" "$@" >"$RX_DIR/receiver.log" 2>&1 &
  RX_PID=$!
}

# Wait for the phone to actually reach the receiver (ConnectMessage on the wire).
rx_wait_connect() {
  local waited=0 limit="${1:-12}"
  while [ "$waited" -lt "$limit" ]; do
    if grep -q '"kind": "connect"' "$RX_JSONL" 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "$RX_PID" 2>/dev/null; then
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

rx_stop() {
  wait "$RX_PID" 2>/dev/null
  RX_RC=$?
}

# run_session <case-dir> <seconds> <receiver-extra-args...>
# One streaming session against the fake desktop. Success is read from the
# receiver's capture file rather than from the phone's status text, which is
# localized. Env: NO_STOP=1 leaves the session to die on its own (heartbeat case),
# MUTE_AFTER=<s> mutes and unmutes inside the window (FEC group continuity case).
run_session() {
  local dir="$1" seconds="$2"
  shift 2
  local pid
  pid="$(d_pid)"
  [ -n "$pid" ] || fail "app not running"
  d_hilog_clear
  rx_start "$dir" "$seconds" "$@"
  sleep 1.0
  d_tap_fab
  if ! rx_wait_connect; then
    d_hilog "$dir/app.log" "$pid"
    fail "no ConnectMessage reached $DESKTOP_IP:$TEST_TCP_PORT (see $dir/receiver.log, $dir/app.log)"
  fi
  if [ -n "${MUTE_AFTER:-}" ]; then
    sleep "$MUTE_AFTER"
    d_tap_mute
    sleep "$(( (seconds - MUTE_AFTER) / 2 ))"
    d_tap_mute
    sleep "$(( seconds - MUTE_AFTER - (seconds - MUTE_AFTER) / 2 ))"
  else
    sleep "$seconds"
  fi
  if [ -z "${NO_STOP:-}" ]; then
    d_tap_fab
  fi
  rx_stop
  d_hilog "$dir/app.log" "$pid"
  [ "${RX_RC:-0}" = "0" ] || log "receiver exited ${RX_RC} (see $dir/receiver.log)"
}

d_ready() {
  # Bring the phone to a known state for a session case: attached, awake, running
  # this build, pointed at the fake desktop through the manual host/port fields.
  # SKIP_INSTALL=1 reuses whatever is already installed (faster, for iterating).
  d_require_device
  d_wake
  if [ -z "${SKIP_INSTALL:-}" ]; then
    d_install
  fi
  d_launch >/dev/null
  [ -n "$(d_pid)" ] || fail "app is not running after launch"
  d_set_target "$DESKTOP_IP" "$TEST_TCP_PORT"
}
