#!/bin/bash
# Run a PowerShell script (stdin) inside the "Windows 11" Parallels VM.
#
#   scripts/win-vm.sh [--user] < script.ps1
#
# --user runs it as the logged-in Windows user (builds, anything per-user);
# without it, as SYSTEM (machine-wide installs). Extra arguments after
# --user are passed to the script.
#
# Short scripts go in as -EncodedCommand (so quoting survives prlctl). Long
# ones — prlctl refuses command lines past a few KB ("Unable to open new
# session") — are staged in build/win-vm (ignored by git), which the VM sees through
# Parallels' shared Mac home (\\Mac\Home), so they need --user.
user=(); if [ "$1" = "--user" ]; then user=(--current-user); shift; fi
script=$( { echo "\$ProgressPreference = 'SilentlyContinue'"; cat; } )
enc=$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')
if [ ${#enc} -lt 3000 ]; then
  exec prlctl exec "Windows 11" "${user[@]}" powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand "$enc"
fi
if [ ${#user[@]} -eq 0 ]; then
  echo "win-vm.sh: script too long to pass inline; long scripts need --user (SYSTEM can't see \\\\Mac\\Home)" >&2
  exit 2
fi
dir="$(cd "$(dirname "$0")/.." && pwd)/build/win-vm"; mkdir -p "$dir"
name="$(date +%s)-$$.ps1"
printf '%s\n' "$script" > "$dir/$name"
rel="${dir#$HOME/}"; rel="${rel//\//\\}"
prlctl exec "Windows 11" "${user[@]}" powershell -NoProfile -ExecutionPolicy Bypass -File "\\\\Mac\\Home\\$rel\\$name" "$@"
status=$?
rm -f "$dir/$name"
exit $status
