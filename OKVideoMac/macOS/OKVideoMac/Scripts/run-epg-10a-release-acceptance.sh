#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 0 ]]; then
  echo "Usage: run-epg-10a-release-acceptance.sh" >&2
  exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPOSITORY_ROOT="$(cd "$PROJECT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/build-environment.sh"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Volumes/XcodeDev/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
FIXTURE="${OKVIDEOMAC_EPG_10A_FIXTURE:-$PROJECT_DIR/Artifacts/EPG9C4/Resources-v2/200000/fixture.xml}"
PUBLIC_PLAIN="${OKVIDEOMAC_EPG_10A_PUBLIC_PLAIN:-/private/tmp/OKVideoMac-9C3-PublicSources/slingtv.xml}"
PUBLIC_GZIP="${OKVIDEOMAC_EPG_10A_PUBLIC_GZIP:-/private/tmp/OKVideoMac-9C3-PublicSources/slingtv.xml.gz}"
OUTPUT_ROOT="${OKVIDEOMAC_EPG_10A_OUTPUT:-$(mktemp -d /private/tmp/OKVideoMac-EPG10A.XXXXXX)}"
DERIVED_DATA="${OKVIDEOMAC_EPG_10A_DERIVED_DATA:-$OUTPUT_ROOT/AppDerivedData}"
SWIFTPM_SCRATCH="${OKVIDEOMAC_EPG_10A_SWIFTPM_SCRATCH:-$OUTPUT_ROOT/SwiftPM}"
CLANG_CACHE="$OUTPUT_ROOT/ClangModules"
mkdir -p "$OUTPUT_ROOT" "$CLANG_CACHE"

for required in "$FIXTURE" "$PUBLIC_PLAIN" "$PUBLIC_GZIP"; do
  if [[ ! -f "$required" ]]; then
    echo "Required frozen EPG fixture is missing: $required" >&2
    exit 2
  fi
done

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
if [[ -z "${OKVIDEOMAC_NODE_RUNTIME:-}" ]]; then
  echo "A supported Node 22 runtime is required for the Release App build." >&2
  exit 2
fi

FIXTURE_DIGEST="$(shasum -a 256 "$FIXTURE" | awk '{print $1}')"
FIXTURE_DIRECTORY="$(cd "$(dirname "$FIXTURE")" && pwd)"
FIXTURE_NAME="$(basename "$FIXTURE")"
SERVER_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 -m http.server "$SERVER_PORT" --bind 127.0.0.1 --directory "$FIXTURE_DIRECTORY" \
  >"$OUTPUT_ROOT/fixture-server.log" 2>&1 &
SERVER_PID=$!
cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT
FIXTURE_URL="http://127.0.0.1:$SERVER_PORT/$FIXTURE_NAME"
for _ in {1..50}; do
  if curl --silent --fail --head "$FIXTURE_URL" >/dev/null; then
    break
  fi
  sleep 0.1
done
curl --silent --fail --head "$FIXTURE_URL" >/dev/null

echo "10A Release acceptance workspace: $OUTPUT_ROOT"
echo "Building the Release App test host once..."
CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" xcodebuild \
  -project "$PROJECT_DIR/OKVideoMac.xcodeproj" \
  -scheme OKVideoMac \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  ENABLE_TESTABILITY=YES \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=OKVIDEO_PERFORMANCE_TEST \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing >"$OUTPUT_ROOT/app-build.log" 2>&1

BASE_XCTESTRUN="$(find "$DERIVED_DATA/Build/Products" -maxdepth 1 -name '*.xctestrun' -print -quit)"
if [[ -z "$BASE_XCTESTRUN" ]]; then
  echo "Release build did not create an xctestrun file." >&2
  exit 3
fi

for run in 1 2 3; do
  echo "Running Release AppKit/App process gate $run/3..."
  run_xctestrun="$(dirname "$BASE_XCTESTRUN")/OKVideoMac-10A-run-$run.xctestrun"
  cp "$BASE_XCTESTRUN" "$run_xctestrun"
  plutil -insert OKVideoMacTests.EnvironmentVariables.OKVIDEO_EPG_10A_APP_RESOURCE \
    -string 1 "$run_xctestrun"
  plutil -insert OKVideoMacTests.EnvironmentVariables.OKVIDEO_EPG_10A_FIXTURE_URL \
    -string "$FIXTURE_URL" "$run_xctestrun"
  plutil -insert OKVideoMacTests.EnvironmentVariables.OKVIDEO_EPG_10A_FIXTURE_SHA256 \
    -string "$FIXTURE_DIGEST" "$run_xctestrun"
  plutil -insert OKVideoMacTests.EnvironmentVariables.OKVIDEO_EPG_10A_APP_OUTPUT \
    -string "$OUTPUT_ROOT/app-run-$run.json" "$run_xctestrun"
  cp "$run_xctestrun" "$OUTPUT_ROOT/app-run-$run.xctestrun"
  CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" xcodebuild \
    -xctestrun "$run_xctestrun" \
    -destination 'platform=macOS,arch=arm64' \
    test-without-building \
    -only-testing:OKVideoMacTests/LiveGuideReleaseResourceTests/testReleaseProductionGuideRenderResourceGate \
    -resultBundlePath "$OUTPUT_ROOT/app-run-$run.xcresult" \
    >"$OUTPUT_ROOT/app-run-$run.log" 2>&1
  if [[ ! -s "$OUTPUT_ROOT/app-run-$run.json" ]]; then
    echo "Release App gate $run did not emit its evidence JSON." >&2
    exit 3
  fi
done

for run in 1 2 3; do
  echo "Running Release Store query matrix $run/3..."
  OKVIDEO_EPG_10A_QUERY_RESOURCE=1 \
  OKVIDEO_EPG_10A_QUERY_OUTPUT="$OUTPUT_ROOT/query-run-$run.json" \
  CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" \
  SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_CACHE" \
  swift test --configuration release \
    --scratch-path "$SWIFTPM_SCRATCH" \
    --package-path "$PROJECT_DIR/Packages/OKVideoKit" \
    --filter EPGCacheQueryResourceTests/test10AGuideWindowQueryReleaseMatrix \
    >"$OUTPUT_ROOT/query-run-$run.log" 2>&1
done

echo "Replaying the frozen public XMLTV sample through the current Release repository..."
for format in plain gzip; do
  if [[ "$format" == plain ]]; then
    input="$PUBLIC_PLAIN"
  else
    input="$PUBLIC_GZIP"
  fi
  EPG9C4_PUBLIC_FILE="$input" \
  EPG9C4_PUBLIC_ORACLE="$PUBLIC_PLAIN" \
  CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" \
  SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_CACHE" \
  swift test --configuration release \
    --scratch-path "$SWIFTPM_SCRATCH" \
    --package-path "$PROJECT_DIR/Packages/OKVideoKit" \
    --filter EPGImportAcceptanceTests/testProductionPublicXMLTVFiniteQueriesMatchLegacyOracle \
    >"$OUTPUT_ROOT/public-$format.log" 2>&1
done

PYTHONDONTWRITEBYTECODE=1 python3 "$REPOSITORY_ROOT/Tools/SourceAudit/epg10a_acceptance.py" \
  --root "$OUTPUT_ROOT"
echo "Verified EPG 10A Release acceptance: $OUTPUT_ROOT"
