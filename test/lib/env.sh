# Sourced by every script under test/. Resolves the toolchain, the phone, and
# the addresses the fake desktop receiver listens on.
#
# Override any of these from the environment: HDC, BUNDLE, PY, TEST_TCP_PORT,
# DESKTOP_IP, RESULTS_ROOT.

TEST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(cd "$TEST_LIB_DIR/.." && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

HDC="${HDC:-/opt/devecostudio/sdk/default/openharmony/toolchains/hdc}"
BUNDLE="${BUNDLE:-com.zhh7ce.micyou.hmos}"
ABILITY=EntryAbility
HAP="$REPO_ROOT/entry/build/default/outputs/default/entry-default-signed.hap"
PY="${PY:-python3}"

# The fake desktop listens on its own control port so it never collides with the
# real GUI on 8554; audio goes to this port + 1, as on the real server.
TEST_TCP_PORT="${TEST_TCP_PORT:-8555}"
TEST_UDP_PORT="$((TEST_TCP_PORT + 1))"

# Address of this machine as the phone sees it. The receiver binds 0.0.0.0, so
# only the advertisement matters here.
DESKTOP_IP="${DESKTOP_IP:-$(ip route get 8.8.8.8 2>/dev/null |
  sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)}"

# run.sh exports one stamp for the whole sweep so every case writes into the same
# results directory; sourcing a script directly makes its own.
RUN_STAMP="${RUN_STAMP:-$(date +%Y%m%d-%H%M%S)}"
RESULTS_ROOT="${RESULTS_ROOT:-$TEST_DIR/results}"
RESULTS_DIR="${RESULTS_DIR:-$RESULTS_ROOT/$RUN_STAMP}"

# run.sh exports CASE_DIR per case; sourcing a case directly falls back to one
# named after the script.
CASE_NAME="${CASE_NAME:-$(basename "${0%.sh}")}"
CASE_DIR="${CASE_DIR:-$RESULTS_DIR/$CASE_NAME}"
mkdir -p "$CASE_DIR"


# Session length for the streaming cases. 30 s gives 1500 opus frames, i.e. 125
# FEC groups, so a cadence mistake cannot hide in the noise.
SESSION_SECONDS="${SESSION_SECONDS:-30}"

mkdir -p "$RESULTS_DIR"

log() { printf '%s %s\n' "[test]" "$*"; }
fail() { printf '%s FAIL %s\n' "[test]" "$*" >&2; exit 1; }
