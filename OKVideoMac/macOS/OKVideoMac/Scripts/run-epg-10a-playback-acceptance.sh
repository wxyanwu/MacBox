#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 0 ]]; then
  echo "Usage: run-epg-10a-playback-acceptance.sh" >&2
  exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/build-environment.sh"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Volumes/XcodeDev/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
OUTPUT_ROOT="${OKVIDEOMAC_EPG_10A_PLAYBACK_OUTPUT_ROOT:-$(mktemp -d /private/tmp/OKVideoMac-EPG10A-Playback.XXXXXX)}"
DERIVED_DATA="${OKVIDEOMAC_EPG_10A_PLAYBACK_DERIVED_DATA:-$OUTPUT_ROOT/DerivedData}"
CLANG_CACHE="$OUTPUT_ROOT/ClangModules"
FIXTURE="${OKVIDEOMAC_EPG_10A_FIXTURE:-$PROJECT_DIR/Artifacts/EPG9C4/Resources-v2/200000/fixture.xml}"
TOTAL_SECONDS="${OKVIDEOMAC_EPG_10A_PLAYBACK_SECONDS:-1800}"
FFMPEG="${OKVIDEOMAC_FFMPEG:-/Applications/Downie 4.app/Contents/Resources/ffmpeg}"
MEDIA="${OKVIDEOMAC_EPG_10A_PLAYBACK_MEDIA:-$OUTPUT_ROOT/local-acceptance.mp4}"
mkdir -p "$OUTPUT_ROOT" "$CLANG_CACHE"

[[ -f "$FIXTURE" ]] || { echo "Missing EPG fixture: $FIXTURE" >&2; exit 2; }
[[ -x "$FFMPEG" ]] || { echo "Missing ffmpeg: $FFMPEG" >&2; exit 2; }

NODE_CANDIDATES=(
  "${OKVIDEOMAC_NODE_RUNTIME:-}"
  "/opt/homebrew/opt/node@22-direct/bin/node"
  "/opt/local/bin/node"
)
for candidate in "${NODE_CANDIDATES[@]}"; do
  if [[ -x "$candidate" ]] && [[ "$($candidate --version 2>/dev/null || true)" == v22.* ]]; then
    export OKVIDEOMAC_NODE_RUNTIME="$candidate"
    break
  fi
done
[[ -n "${OKVIDEOMAC_NODE_RUNTIME:-}" ]] || { echo "Node 22 is required." >&2; exit 2; }

if [[ ! -f "$MEDIA" ]]; then
  # Keep playback running while the successful 200K EPG refresh is imported.
  # The margin is deliberately independent of the measured import duration.
  media_seconds="$(python3 -c 'import sys; print(max(90.0, float(sys.argv[1]) / 6.0 + 90.0))' "$TOTAL_SECONDS")"
  echo "Generating deterministic local media (${media_seconds}s)..."
  "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=320x180:rate=15" \
    -f lavfi -i "sine=frequency=880:sample_rate=48000" \
    -t "$media_seconds" -c:v libopenh264 -b:v 220k -pix_fmt yuv420p \
    -c:a aac -b:a 48k -movflags +faststart "$MEDIA"
fi

fixture_directory="$(cd "$(dirname "$FIXTURE")" && pwd)"
fixture_name="$(basename "$FIXTURE")"
server_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 -m http.server "$server_port" --bind 127.0.0.1 --directory "$fixture_directory" \
  >"$OUTPUT_ROOT/fixture-server.log" 2>&1 &
server_pid=$!
cleanup() {
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT
fixture_url="http://127.0.0.1:$server_port/$fixture_name"
for _ in {1..50}; do
  if curl --silent --fail --head "$fixture_url" >/dev/null; then break; fi
  sleep 0.1
done
curl --silent --fail --head "$fixture_url" >/dev/null

echo "Building Release playback test host..."
CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" xcodebuild \
  -project "$PROJECT_DIR/OKVideoMac.xcodeproj" \
  -scheme OKVideoMac -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" ENABLE_TESTABILITY=YES \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=OKVIDEO_PERFORMANCE_TEST \
  CODE_SIGNING_ALLOWED=NO build-for-testing >"$OUTPUT_ROOT/build.log" 2>&1

base_xctestrun="$(find "$DERIVED_DATA/Build/Products" -maxdepth 1 -name '*.xctestrun' -print -quit)"
[[ -n "$base_xctestrun" ]] || { echo "Release build did not create an xctestrun." >&2; exit 3; }
run_xctestrun="$(dirname "$base_xctestrun")/OKVideoMac-10A-playback.xctestrun"
cp "$base_xctestrun" "$run_xctestrun"
plutil -insert OKVideoMacTests.EnvironmentVariables.OKVIDEO_EPG_10A_PLAYBACK -string 1 "$run_xctestrun"
plutil -insert OKVideoMacTests.EnvironmentVariables.OKVIDEO_EPG_10A_MEDIA -string "$MEDIA" "$run_xctestrun"
plutil -insert OKVideoMacTests.EnvironmentVariables.OKVIDEO_EPG_10A_FIXTURE_URL -string "$fixture_url" "$run_xctestrun"
plutil -insert OKVideoMacTests.EnvironmentVariables.OKVIDEO_EPG_10A_PLAYBACK_SECONDS -string "$TOTAL_SECONDS" "$run_xctestrun"
plutil -insert OKVideoMacTests.EnvironmentVariables.OKVIDEO_EPG_10A_PLAYBACK_OUTPUT \
  -string "$OUTPUT_ROOT/playback.json" "$run_xctestrun"
cp "$run_xctestrun" "$OUTPUT_ROOT/playback.xctestrun"

echo "Running deterministic playback for ${TOTAL_SECONDS}s..."
CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" xcodebuild \
  -xctestrun "$run_xctestrun" -destination 'platform=macOS,arch=arm64' \
  test-without-building \
  -only-testing:OKVideoMacTests/LiveGuidePlaybackAcceptanceTests/testThirtyMinuteLocalPlaybackRemainsIndependentFromEPG \
  -resultBundlePath "$OUTPUT_ROOT/playback.xcresult" 2>&1 | tee "$OUTPUT_ROOT/playback.log"
[[ -s "$OUTPUT_ROOT/playback.json" ]] || { echo "Playback acceptance emitted no JSON." >&2; exit 3; }
echo "Verified EPG 10A local playback acceptance: $OUTPUT_ROOT"
