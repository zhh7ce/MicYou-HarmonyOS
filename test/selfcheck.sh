#!/usr/bin/env bash
# test/selfcheck.sh — does the harness itself tell the truth?
#
# Part 1 runs the shell library against a synthetic widget tree and a stubbed hdc:
# chip opacity, odd-colour selection, geometry-based button lookup, and the
# click-delete-retype round trip on a text field. No phone involved.
#
# Part 2 runs lib/fakephone.py (an independent, deliberately correct emitter) against
# receiver.py and analyze.py, then repeats it with exactly one defect seeded per run.
# Every gate must trip for its own defect and stay green for the rest — that is what
# catches an assertion that can never fail. It binds its own port pair, so the real
# desktop on 8554 is untouched.
#
# Needs a system libopus for part 2; skipped with a note if it is missing.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export RESULTS_ROOT="$T"
. "$HERE/lib/env.sh"

SELFTEST_TCP_PORT="${SELFTEST_TCP_PORT:-18555}"
UDP_PORT="$((SELFTEST_TCP_PORT + 1))"
SECS="${SELFCHECK_SECONDS:-3}"

fails=0
step() { printf '\n== %s\n' "$*"; }
check() {
  local what="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    printf 'ok   %-46s %s\n' "$what" "$got"
  else
    printf 'FAIL %-46s got=%s want=%s\n' "$what" "$got" "$want"
    fails=$((fails + 1))
  fi
}

# ---------------------------------------------------------------- part 1: the library
cat >"$T/base-layout.json" <<'JSON'
{"attributes": {"type": "Page", "text": "", "bounds": "[0,0][1224,2776]"}, "children": [
 {"attributes": {"type": "Text", "text": "16 kHz", "bounds": "[10,900][300,980]", "backgroundColor": "#FF1E293B", "opacity": "1", "clickable": "true"}, "children": []},
 {"attributes": {"type": "Text", "text": "44.1 kHz", "bounds": "[10,1000][300,1080]", "backgroundColor": "#FF1E293B", "opacity": "0.5", "clickable": "true"}, "children": []},
 {"attributes": {"type": "Text", "text": "48 kHz", "bounds": "[10,1100][300,1180]", "backgroundColor": "#FF6750A4", "opacity": "1", "clickable": "true"}, "children": []},
 {"attributes": {"type": "Text", "text": "96 kHz", "bounds": "[10,1200][300,1280]", "backgroundColor": "#FF1E293B", "opacity": "0.5", "clickable": "true"}, "children": []},
 {"attributes": {"type": "Text", "text": "16-bit", "bounds": "[10,1400][300,1480]", "backgroundColor": "#FF6750A4", "opacity": "1", "clickable": "true"}, "children": []},
 {"attributes": {"type": "Text", "text": "24-bit", "bounds": "[10,1500][300,1580]", "backgroundColor": "#FF1E293B", "opacity": "0.5", "clickable": "true"}, "children": []},
 {"attributes": {"type": "Text", "text": "32-bit float", "bounds": "[10,1600][300,1680]", "backgroundColor": "#FF1E293B", "opacity": "0.5", "clickable": "true"}, "children": []},
 {"attributes": {"type": "Text", "text": "单声道", "bounds": "[10,700][300,780]", "backgroundColor": "#FF6750A4", "opacity": "1", "clickable": "true"}, "children": []},
 {"attributes": {"type": "Text", "text": "自动连接", "bounds": "[40,1900][400,1960]", "clickable": "false"}, "children": []},
 {"attributes": {"type": "TextInput", "text": "192.168.1.5", "bounds": "[40,400][700,470]", "clickable": "true"}, "children": []},
 {"attributes": {"type": "TextInput", "text": "8554", "bounds": "[40,500][700,570]", "clickable": "true"}, "children": []},
 {"attributes": {"type": "Button", "text": "", "bounds": "[450,1250][770,1570]", "clickable": "true"}, "children": []},
 {"attributes": {"type": "Button", "text": "", "bounds": "[1100,120][1180,200]", "clickable": "true"}, "children": []}
]}
JSON

cat >"$T/screen.py" <<'PY'
"""Stateful stand-in for the phone screen: applies one uitest command to the layout."""
import json
import re
import sys

LAYOUT, FOCUS = sys.argv[1], sys.argv[2]


def fields(tree):
    return [n for n in tree["children"] if n["attributes"].get("type") == "TextInput"]


with open(LAYOUT, encoding="utf-8") as handle:
    tree = json.load(handle)
items = fields(tree)
command = " ".join(sys.argv[3:])
click = re.match(r"uitest uiInput click (\d+) (\d+)", command)
if click:
    y = int(click.group(2))
    chosen = 0
    for i, field in enumerate(items):
        top = int(re.match(r"\[\d+,(\d+)\]", field["attributes"]["bounds"]).group(1))
        if y > top:
            chosen = i
    open(FOCUS, "w").write(str(chosen))
elif command == "uitest uiInput keyEvent 2055":
    field = items[int(open(FOCUS).read())]
    field["attributes"]["text"] = field["attributes"]["text"][:-1]
elif command.startswith("uitest uiInput text "):
    field = items[int(open(FOCUS).read())]
    field["attributes"]["text"] += command[len("uitest uiInput text "):]
else:
    sys.exit(0)
json.dump(tree, open(LAYOUT, "w", encoding="utf-8"))
PY

. "$HERE/lib/device.sh"
. "$HERE/lib/settings.sh"
TAP_SETTLE=0

# hdc is the only thing being replaced; the layout file stands in for the screen and
# keeps its state between dumps, so a text edit is observable.
d_shell() {
  case "$*" in
    *"dumpLayout"*) echo "Stub: DumpLayout" ;;
    *"uiInput "*) "$PY" "$T/screen.py" "$T/layout.json" "$T/focus" "$*" ;;
    *) echo "stub-shell: $*" ;;
  esac
}
d_dump() {
  [ -f "$T/layout.json" ] || cp "$T/base-layout.json" "$T/layout.json"
  LAYOUT="$T/layout.json"
}

step "part 1: widget-tree queries"
d_dump
check "greyed chip opacity" "$(q --type Text --text "44.1 kHz" --out opacity)" "0.5"
check "live chip opacity" "$(q --type Text --text "48 kHz" --out opacity)" "1"
check "d_chip_attr forwards" "$(d_chip_attr opacity "96 kHz")" "0.5"
check "FAB found by area" "$(q --type Button --clickable true --min-area 60000 --out center)" "610 1410"
check "gear found by geometry" "$(q --type Button --clickable true --top-lt 420 --out center)" "1140 160"
check "mute-pill filter excludes the FAB" \
  "$(q --type Button --clickable true --left-lt 400 --bottom-gt 2000 --out count)" "0"

step "part 1: the assertions report what they claim"
if ( d_assert_selected "48 kHz" "${S_RATES[@]}" 2>"$T/a1" ); then
  check "odd-colour selection passes" pass pass
else
  check "odd-colour selection passes" "fail: $(cat "$T/a1")" pass
fi
if ( d_assert_selected "16 kHz" "${S_RATES[@]}" 2>/dev/null ); then
  check "wrong selection is caught" pass fail
else
  check "wrong selection is caught" fail fail
fi
if ( d_tap_label "单声道" 2>/dev/null ); then
  check "locale label tapped" pass pass
else
  check "locale label tapped" pass fail
fi
if ( d_tap_label "Nonexistent" 2>/dev/null ); then
  check "missing label fails loudly" pass fail
else
  check "missing label fails loudly" fail fail
fi

step "part 1: text entry round trip"
d_set_input 1 "8555"
check "port field rewritten" "$(q --type TextInput --out text --nth 1)" "8555"
d_set_input 0 "10.0.0.9"
check "host field rewritten" "$(q --type TextInput --out text --nth 0)" "10.0.0.9"

# --------------------------------------------------------------- part 2: the analyzer
if "$PY" -c "import ctypes; ctypes.CDLL('libopus.so.0')" 2>/dev/null; then
  have_opus=1
else
  have_opus=0
  printf '\n== part 2 skipped: no system libopus to encode or decode with\n'
fi

gates_of() {
  # $1 jsonl, $2 profile -> the space-separated names of the gates that failed
  "$PY" "$HERE/lib/analyze.py" --in "$1" --profile "$2" --min-packets 100 \
    >"$T/analyze.log" 2>&1
  awk '/^FAIL/ {print $2}' "$T/analyze.log" | tr -d ':' | tr '\n' ' '
}

capture() {
  # $1 output jsonl, $2 profile, $3 defect or empty
  rm -f "$1"
  "$PY" "$HERE/lib/receiver.py" --tcp-port "$SELFTEST_TCP_PORT" --udp-port "$UDP_PORT" \
    --duration "$((SECS + 2))" --out "$1" >"$T/rx.log" 2>&1 &
  local pid=$!
  sleep 0.8
  if [ -z "$3" ]; then
    "$PY" "$HERE/lib/fakephone.py" --tcp-port "$SELFTEST_TCP_PORT" --udp-port "$UDP_PORT" \
      --profile "$2" --seconds "$SECS" >/dev/null
  else
    "$PY" "$HERE/lib/fakephone.py" --tcp-port "$SELFTEST_TCP_PORT" --udp-port "$UDP_PORT" \
      --profile "$2" --seconds "$SECS" --break "$3" >/dev/null
  fi
  wait "$pid" 2>/dev/null
}

if [ "$have_opus" = "1" ]; then
  step "part 2: a correct stream passes every gate"
  for profile in opus-48k-mono opus-48k-stereo opus-16k-mono pcm-48k-mono; do
    capture "$T/clean-$profile.jsonl" "$profile" ""
    check "clean $profile" "$(gates_of "$T/clean-$profile.jsonl" "$profile")" ""
  done

  step "part 2: each seeded defect trips exactly its own gate"
  for defect in "xor fec-xor" "parity-seq fec-seq-reuse" "lengths fec-xor" \
                "group-start fec-group-start" "rate header" "payload payload"; do
    set -- $defect
    local_break="$1"
    want="$2"
    profile=opus-48k-mono
    [ "$local_break" = payload ] && profile=pcm-48k-mono
    capture "$T/broken-$local_break.jsonl" "$profile" "$local_break"
    gates=" $(gates_of "$T/broken-$local_break.jsonl" "$profile") "
    check "$local_break trips $want" \
      "$([ "${gates#* $want }" != "$gates" ] && echo caught)" caught
    if [ "$local_break" != rate ] && [ "$local_break" != payload ]; then
      # the defect must stay local, otherwise the run proves nothing about $want
      untouched="$gates"
      check "$local_break leaves sequence/header/fec-cadence alone" \
        "$([ "${untouched#* sequence }" = "$untouched" ] &&
          [ "${untouched#* header }" = "$untouched" ] &&
          [ "${untouched#* fec-cadence }" = "$untouched" ] && echo isolated)" isolated
    fi
  done

  step "part 2: an empty capture cannot pass"
  rm -f "$T/empty.jsonl"
  "$PY" "$HERE/lib/receiver.py" --tcp-port "$SELFTEST_TCP_PORT" --udp-port "$UDP_PORT" \
    --duration 2 --out "$T/empty.jsonl" >/dev/null 2>&1
  gates=" $(gates_of "$T/empty.jsonl" opus-48k-mono) "
  check "silence is not a green run" \
    "$([ "${gates#* volume }" != "$gates" ] && echo caught)" caught
fi

printf '\n%s\n' "$([ "$fails" = 0 ] \
  && echo 'selfcheck passed: every gate in the suite can actually fail' \
  || echo "$fails selfcheck failure(s)")"
exit "$fails"
