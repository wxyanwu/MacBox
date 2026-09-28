#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
README="$PROJECT_DIR/../../README.md"
REPOSITORY_ROOT="$(cd "$PROJECT_DIR/../../.." && pwd)"
ROOT_README="$REPOSITORY_ROOT/README.md"
ROOT_README_ZH="$REPOSITORY_ROOT/README_zh-CN.md"
CHANGELOG="$REPOSITORY_ROOT/CHANGELOG.md"
NOTICES="$PROJECT_DIR/../../THIRD_PARTY_NOTICES.md"
NATIVE_LOCK="$REPOSITORY_ROOT/ThirdParty/native-lock.json"
SOURCE_RELEASE_PROCESS="$REPOSITORY_ROOT/Docs/SOURCE_RELEASE_PROCESS.md"
COMPATIBILITY="$PROJECT_DIR/Docs/COMPATIBILITY.md"
PERFORMANCE="$PROJECT_DIR/Docs/PERFORMANCE.md"
PROJECT_YAML="$PROJECT_DIR/project.yml"

read_setting() {
  setting="$1"
  awk -v setting="$setting" '
    $1 == setting ":" {
      gsub(/["[:space:]]/, "", $2)
      print $2
      exit
    }
  ' "$PROJECT_YAML"
}

VERSION="$(read_setting MARKETING_VERSION)"
BUILD="$(read_setting CURRENT_PROJECT_VERSION)"
if [[ -z "$VERSION" || -z "$BUILD" ]]; then
  echo "Unable to read version metadata from $PROJECT_YAML" >&2
  exit 1
fi

assert_exact_line() {
  file="$1"
  expected="$2"
  if ! grep -Fqx -- "$expected" "$file"; then
    echo "Documentation metadata is stale: $file" >&2
    echo "Expected exact line: $expected" >&2
    exit 1
  fi
}

assert_contains() {
  file="$1"
  expected="$2"
  if ! grep -Fq -- "$expected" "$file"; then
    echo "Documentation metadata is stale: $file" >&2
    echo "Expected text: $expected" >&2
    exit 1
  fi
}

# The upstream evidence documents retain their original 0.6.1 metadata.
# Check current product metadata separately instead of relabelling old tests.
assert_exact_line "$ROOT_README" "# MacBox"
assert_exact_line "$ROOT_README_ZH" "# MacBox"
assert_exact_line "$ROOT_README" "- Current app version: ${VERSION} (Build ${BUILD})"
assert_exact_line "$ROOT_README_ZH" "- 当前应用版本：${VERSION}（Build ${BUILD}）"
assert_exact_line "$REPOSITORY_ROOT/Docs/RELEASE_NOTES_${VERSION}.md" "# MacBox ${VERSION}（Build ${BUILD}）"
assert_contains "$CHANGELOG" "## [${VERSION}]"
assert_contains "$README" "MacBox"
assert_exact_line "$COMPATIBILITY" "- 对照版本：0.6.1（Build 101）"
assert_exact_line "$PERFORMANCE" "- 对照版本：0.6.1（Build 101）"
assert_contains "$NOTICES" "OKVideoMac 0.6.1 (Build 101)"

PYTHONDONTWRITEBYTECODE=1 python3 - "$PROJECT_DIR" "$VERSION" "$BUILD" <<'PY'
import json
import pathlib
import plistlib
import re
import sys

root, version, build = sys.argv[1:]
root = pathlib.Path(root)
project = (root / "OKVideoMac.xcodeproj/project.pbxproj").read_text()
for key, expected in (("MARKETING_VERSION", version), ("CURRENT_PROJECT_VERSION", build)):
    values = re.findall(rf"\b{key}\s*=\s*([^;]+);", project)
    if not values or any(value.strip().strip('"') != expected for value in values):
        raise SystemExit(f"Xcode project {key} disagrees with project.yml: {values}")
info = plistlib.loads((root / "Supporting/Info.plist").read_bytes())
localized = json.loads((root / "Resources/InfoPlist.xcstrings").read_text())["strings"]
for key in ("CFBundleName", "CFBundleDisplayName"):
    for language, entry in localized[key]["localizations"].items():
        if entry["stringUnit"]["value"] != "MacBox":
            raise SystemExit(f"Localized product name is stale: {key} {language}")
for key in ("CFBundleName", "CFBundleDisplayName"):
    if info.get(key) != "MacBox":
        raise SystemExit(f"Incorrect product name for {key}")
for key, expected in (("CFBundleShortVersionString", "$(MARKETING_VERSION)"),
                      ("CFBundleVersion", "$(CURRENT_PROJECT_VERSION)")):
    if info.get(key) != expected:
        raise SystemExit(f"Info.plist must use the shared build setting for {key}")
PY

PYTHONDONTWRITEBYTECODE=1 python3 - "$NATIVE_LOCK" "$VERSION" "$BUILD" <<'PY'
import json
import sys

path, version, build = sys.argv[1:]
with open(path, encoding="utf-8") as source:
    release = json.load(source).get("release")
expected = f"MacBox {version} ({build})"
if release != expected:
    raise SystemExit(f"Native lock release metadata is stale: {release!r}; expected {expected!r}")
PY

STALE_PATTERN='当前尚未成功构建|当前尚无可运行 App|未构建/链接/播放|Swift/App 未经 Xcode 构建'
if grep -En "$STALE_PATTERN" "$README" "$COMPATIBILITY" "$PERFORMANCE"; then
  echo "Current-status documentation contains an obsolete build claim." >&2
  exit 1
fi

for historical_document in \
  "$PROJECT_DIR/Docs/MIGRATION_STATUS.md" \
  "$PROJECT_DIR/Docs/PLAYER_SPIKE.md"; do
  if ! grep -Fq -- '文档类型：历史' "$historical_document"; then
    echo "Historical document is missing its status banner: $historical_document" >&2
    exit 1
  fi
done

echo "Documentation status check passed: ${VERSION} (Build ${BUILD})"
