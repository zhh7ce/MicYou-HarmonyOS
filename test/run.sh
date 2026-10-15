#!/usr/bin/env bash
# test/run.sh — the single entry point for both tiers of the regression suite.
#
#   ./run.sh --auto                 unattended: fake desktop, real decoding, no questions
#   ./run.sh --human                sits at observation points and waits for your verdict
#   ./run.sh --all                  auto tier, then the human tier
#   ./run.sh --auto --only a03      one case by name prefix
#   ./run.sh --auto --install       build the HAP first (case a01), then run the rest
#   ./run.sh --list                 print the catalogue without touching the phone
#
# Two auto cases are destructive to whatever else is using the phone (they force-stop
# the app, or suspend the screen). They are skipped unless you pass --allow-disruptive.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
export RUN_STAMP RESULTS_DIR RESULTS_ROOT
. "$HERE/lib/env.sh"

CASE_TIMEOUT_SECONDS="${CASE_TIMEOUT_SECONDS:-600}"
TIER=""
ONLY=""
LIST=0
INSTALL_FIRST=0
ALLOW_DISRUPTIVE=0

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --auto) TIER=auto ;;
    --human) TIER=human ;;
    --all) TIER=all ;;
    --only) shift; ONLY="${1:-}"; [ -n "$ONLY" ] || usage ;;
    --install) INSTALL_FIRST=1 ;;
    --allow-disruptive) ALLOW_DISRUPTIVE=1 ;;
    --list) LIST=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) usage ;;
  esac
  shift
done

if [ -z "$TIER" ] && [ "$LIST" != "1" ]; then
  usage
fi

tiers=()
if [ -n "$TIER" ]; then
  [ "$TIER" = all ] && tiers=(auto human) || tiers=("$TIER")
else
  tiers=(auto human)
fi

described() {
  sed -n '2,8p' "$1" | grep -m1 '^#' | sed 's/^# \{0,1\}//'
}

is_disruptive() {
  sed -n '2,10p' "$1" | grep -q disruptive
}

if [ "$LIST" = "1" ]; then
  for tier in "${tiers[@]}"; do
    printf '%s tier:\n' "$tier"
    for file in "$HERE/cases/$tier"/*.sh; do
      [ -e "$file" ] || continue
      marker=""
      is_disruptive "$file" && marker=" [disruptive]"
      printf '  %-34s%s %s\n' "$(basename "${file%.sh}")" "$marker" "$(described "$file")"
    done
  done
  exit 0
fi

mkdir -p "$RESULTS_DIR"
log "results: $RESULTS_DIR"

declare -a ROWS=()
FAILED=0
RAN=()

# run_case <tier> <file> [force]  — force bypasses --only, for the --install preflight.
run_case() {
  local tier="$1" file="$2" force="${3:-}"
  local name rc start took
  name="$(basename "${file%.sh}")"
  if [ -n "$ONLY" ] && [ "$force" != force ] && [ "${name#"$ONLY"}" = "$name" ]; then
    return 0
  fi
  if is_disruptive "$file" && [ "$ALLOW_DISRUPTIVE" != "1" ]; then
    ROWS+=("SKIP $tier/$name (disruptive — pass --allow-disruptive)")
    log "skipped $name (disruptive)"
    return 0
  fi
  log "running $tier/$name"
  start="$(date +%s)"
  if [ "$tier" = human ]; then
    # The human tier reads verdicts from stdin and prints what to look at, so it
    # stays attached to the terminal instead of being piped through tee.
    CASE_NAME="$name" CASE_DIR="$RESULTS_DIR/$name" bash "$file"
    rc=$?
  else
    CASE_NAME="$name" CASE_DIR="$RESULTS_DIR/$name" \
      timeout --kill-after=30 "$CASE_TIMEOUT_SECONDS" bash "$file" 2>&1 |
      tee "$RESULTS_DIR/$name.out"
    rc="${PIPESTATUS[0]}"
  fi
  took=$(( $(date +%s) - start ))
  RAN+=("$tier/$name")
  if [ "$rc" = "0" ]; then
    ROWS+=("PASS $tier/$name (${took}s)")
  else
    ROWS+=("FAIL $tier/$name (exit $rc, ${took}s)")
    FAILED=1
  fi
}

if [ "$INSTALL_FIRST" = "1" ]; then
  run_case auto "$HERE/cases/auto/a01_build_hap.sh" force
fi

for tier in "${tiers[@]}"; do
  for file in "$HERE/cases/$tier"/*.sh; do
    [ -e "$file" ] || continue
    run_case "$tier" "$file"
  done
done

if [ "${#ROWS[@]}" -eq 0 ]; then
  fail "no case matched"
fi

printf '\n==== summary ====\n'
for row in "${ROWS[@]}"; do
  printf '%s\n' "$row"
done
printf 'logs: %s\n' "$RESULTS_DIR"
exit "$FAILED"
