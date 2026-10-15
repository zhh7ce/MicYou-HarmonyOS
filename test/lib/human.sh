# Sourced by the human-tier cases after env.sh and device.sh.
#
# These cases cannot decide their own result: what is being checked is how the
# desktop GUI reacts and how the audio sounds, which no widget tree reports. So the
# script drives everything it can (profile, target, taps, timing) and then stops at
# an observation point: it prints exactly what to look at, waits for a verdict, and
# appends that verdict to results/<stamp>/human.log.

HUMAN_LOG="$RESULTS_DIR/human.log"

h_require_tty() {
  [ -t 0 ] || fail "human cases need a terminal: run them from an interactive shell"
}

h_observe() {
  # $1 = title, $2 = the checklist to read on screen.
  printf '\n\033[1m──── OBSERVE · %s ────\033[0m\n%s\n\033[1m─────────────────────────────\033[0m\n\n' \
    "$1" "$2" | tee -a "$HUMAN_LOG"
}

h_step() {
  printf '[test] %s\n' "$*" | tee -a "$HUMAN_LOG"
}

h_wait() {
  # $1 = prompt shown before blocking.
  printf '[test] %s (press Enter) ' "$*"
  local _
  read -r _ || fail "stdin is not interactive"
}

h_verdict() {
  # $1 = short description of what passing means.
  local answer
  while :; do
    printf '[test] verdict for %s — %s [pass/fail/skip]: ' "$CASE_NAME" "$1"
    if ! read -r answer; then
      answer=skip
    fi
    case "${answer:-skip}" in
      pass)
        printf '%s %s PASS %s\n' "$(date '+%F %T')" "$CASE_NAME" "$1" | tee -a "$HUMAN_LOG"
        return 0
        ;;
      fail)
        printf '%s %s FAIL %s\n' "$(date '+%F %T')" "$CASE_NAME" "$1" | tee -a "$HUMAN_LOG"
        fail "recorded as fail"
        ;;
      skip)
        printf '%s %s SKIP %s\n' "$(date '+%F %T')" "$CASE_NAME" "$1" | tee -a "$HUMAN_LOG"
        log "recorded as skipped"
        return 0
        ;;
      *) log "answer pass, fail or skip" ;;
    esac
  done
}
