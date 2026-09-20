#!/usr/bin/env bash
# Explicitly local, uncommitted acceptance only. Never installs or publishes.
set -euo pipefail
if [[ "$#" -ne 0 ]]; then
  echo "Usage: package-local-acceptance.sh (local only; no arguments)" >&2
  exit 64
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# All destinations are fresh and outside File Provider / the source worktree.
ACCEPTANCE_ROOT="$(mktemp -d /private/tmp/OKVideoMac-Acceptance.XXXXXX)"
SNAPSHOT_ROOT="$ACCEPTANCE_ROOT/Source"
echo "Local acceptance workspace: $ACCEPTANCE_ROOT"
export PYTHONDONTWRITEBYTECODE=1
python3 "$REPOSITORY_ROOT/Tools/SourceAudit/local_acceptance.py" \
  --repo "$REPOSITORY_ROOT" --destination "$SNAPSHOT_ROOT"
export OKVIDEOMAC_DERIVED_DATA="$ACCEPTANCE_ROOT/DerivedData"
export OKVIDEOMAC_ARTIFACTS="$ACCEPTANCE_ROOT/Artifacts"
export OKVIDEOMAC_SOURCE_RELEASE_DIR="$ACCEPTANCE_ROOT/Artifacts/SourceRelease"
# Dependencies are the same builder inputs used by the standard package flow.
export OKVIDEOMAC_BUILD_ROOT="${OKVIDEOMAC_BUILD_ROOT:-$REPOSITORY_ROOT/OKVideoMac/macOS/OKVideoMac/Vendor/Build}"
# Always build the APK from the captured source, never reuse a potentially
# unrelated worktree APK. Existing developer signing storage is unchanged.
export OKVIDEOMAC_SKIP_ANDROID_BRIDGE_BUILD=0
bash "$SNAPSHOT_ROOT/OKVideoMac/macOS/OKVideoMac/Scripts/package-app.sh" \
  --mode local --local-acceptance
python3 "$SNAPSHOT_ROOT/Tools/SourceAudit/local_acceptance.py" --repo "$SNAPSHOT_ROOT" --verify
echo "Verified LOCAL acceptance only: $ACCEPTANCE_ROOT/Artifacts/OKVideoMac.app"
