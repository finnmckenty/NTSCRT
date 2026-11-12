#!/bin/bash
# Check out librashader at the commit the Mac app pins (see DEVELOPMENT.md)
# into port/vendor/librashader and apply port/librashader-wgpu-push-constants.patch.
#
# The patch restores the wgpu pipeline-layout entry for push-constant blocks
# that 5281c781 ("Bump wgpu 27 -> 28") dropped; without it every shader fails
# with "Binding is missing from the pipeline layout". Upstream fixed it in
# 90d88d5a (2026-05-21); drop the patch if the pin ever moves past that.
# Safe to re-run.
set -euo pipefail
PIN=76462c030b75c4f2d56e5386c3d4d7d1128318b8
here="$(cd "$(dirname "$0")" && pwd)"
dest="$here/vendor/librashader"
patch="$here/librashader-wgpu-push-constants.patch"
if [ ! -d "$dest/.git" ]; then
  mkdir -p "$here/vendor"
  git clone --quiet https://github.com/SnowflakePowered/librashader.git "$dest"
fi
git -C "$dest" checkout --quiet "$PIN"
if git -C "$dest" apply --reverse --check "$patch" 2>/dev/null; then
  echo "librashader $PIN: patch already applied"
else
  git -C "$dest" apply "$patch"
  echo "librashader $PIN: patched"
fi
