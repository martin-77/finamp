#!/usr/bin/env bash
set -euo pipefail

BRANCH="test/performance-benchmark-harness"
OUT_DIR="${FINAMP_BENCH_OUT:-benchmark-results}"

fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

command -v git >/dev/null || fail "git not found"
command -v flutter >/dev/null || fail "flutter not found"
command -v python3 >/dev/null || fail "python3 not found"
command -v xcodebuild >/dev/null || fail "Xcode command line tools not found"
command -v pod >/dev/null || fail "CocoaPods not found"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "Run this inside the Finamp repository"

# Allow known machine-local iOS/dev files while still refusing to run over
# real source changes. These files may be required for local signing/build setup.
dirty_lines="$(git status --porcelain | python3 -c '
import sys
allowed_exact = {
    " M ios/Podfile.lock",
    " M ios/Runner.xcodeproj/project.pbxproj",
    " D ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    " D ios/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    " M ios/Runner/Info-Debug.plist",
    " M ios/Runner/Info-Profile.plist",
    " M ios/Runner/Info-Release.plist",
    " M ios/Runner/Runner.entitlements",
    " M pubspec.lock",
    "?? ios/Runner/RunnerDebug.entitlements",
    "?? ios/Runner/RunnerRelease.entitlements",
    "?? pubspec_overrides.yaml",
}
allowed_prefixes = (
    "?? benchmark-results/",
    "?? \"Build Runner_",
)
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    if line in allowed_exact:
        continue
    if any(line.startswith(prefix) for prefix in allowed_prefixes):
        continue
    print(line)
')"
if [[ -n "$dirty_lines" ]]; then
  printf '%s\n' "$dirty_lines" >&2
  fail "Working tree contains source/tracked changes. Restore/commit/stash those first; known local entitlements and pubspec_overrides.yaml are allowed."
fi

step "Fetching benchmark branch"
git fetch origin "$BRANCH"

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git switch "$BRANCH"
  git merge --ff-only "origin/$BRANCH"
else
  git switch --track -c "$BRANCH" "origin/$BRANCH"
fi

step "Flutter / Xcode sanity checks"
flutter --version
xcodebuild -version
pod --version

step "Resolving Flutter dependencies"
flutter pub get

step "Checking iOS pods"
(
  cd ios
  pod install
)

step "Finding a physical iOS device"
DEVICE_ID="${1:-}"
if [[ -z "$DEVICE_ID" ]]; then
  set +e
  DEVICE_ID="$(flutter devices --machine | python3 -c '
import json,sys
devices=json.load(sys.stdin)
physical=[d for d in devices if d.get("targetPlatform")=="ios" and not d.get("emulator",False)]
if len(physical)==1:
    print(physical[0]["id"])
elif len(physical)==0:
    sys.exit(2)
else:
    sys.exit(3)
')"
  status=$?
  set -e

  if [[ "$status" -eq 2 ]]; then
    flutter devices
    fail "No physical iOS device found. Connect/unlock/trust the iPhone and try again."
  elif [[ "$status" -eq 3 ]]; then
    flutter devices
    fail "More than one physical iOS device found. Re-run with the device id as the only argument."
  elif [[ "$status" -ne 0 ]]; then
    fail "Could not determine iOS device."
  fi
fi

step "Selected device: $DEVICE_ID"
mkdir -p "$OUT_DIR"

step "Starting Finamp benchmark build in PROFILE mode"
printf 'Results will be written continuously under %s/\n' "$OUT_DIR"
printf 'Keep this terminal open for the whole run. Ctrl-C stops the app/collector.\n\n'

bash tool/run_performance_benchmark.sh -d "$DEVICE_ID" --profile
