#!/bin/sh
# Xcode build phase: stamps the git revision into the built Info.plist as ElementalBuildInfo, which
# the About window shows after the version number, e.g. "v0.1.12, a1b2c3d" for a release build or
# "a1b2c3d, dirty" for a local build with uncommitted changes to tracked files.
# Leaves the key out when there is no git checkout (e.g. a source tarball).
set -eu

PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
cd "${SRCROOT}"

PLISTBUDDY=/usr/libexec/PlistBuddy
"$PLISTBUDDY" -c "Delete :ElementalBuildInfo" "$PLIST" >/dev/null 2>&1 || true

hash=$(git rev-parse --short HEAD 2>/dev/null) || exit 0
tag=$(git describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null || true)

info="$hash"
[ -n "$tag" ] && info="$tag, $info"
# Untracked files are ignored: Xcode writes some (Package.resolved) during every build.
[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ] && info="$info, dirty"

"$PLISTBUDDY" -c "Add :ElementalBuildInfo string $info" "$PLIST"
