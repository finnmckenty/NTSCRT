#!/bin/sh
# Starts the MCP server built into NTSCRT (`NTSCRT mcp`, 0.26.0 and later).
# The extension carries only this launcher: the server is the installed app.
found=""
for app in "/Applications/NTSCRT.app" "$HOME/Applications/NTSCRT.app" \
           "$(mdfind "kMDItemCFBundleIdentifier == 'academy.urm.ntscrt'" 2>/dev/null | head -1)"; do
  [ -x "$app/Contents/MacOS/NTSCRT" ] || continue
  found="$app"
  v=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist" 2>/dev/null)
  major=$(echo "$v" | cut -d. -f1); minor=$(echo "$v" | cut -d. -f2 | cut -d- -f1)
  case "$major$minor" in *[!0-9]*|"") continue ;; esac
  if [ "$major" -gt 0 ] || [ "$minor" -ge 26 ]; then
    exec "$app/Contents/MacOS/NTSCRT" mcp
  fi
done
if [ -n "$found" ]; then
  echo "NTSCRT at $found is too old for Claude: update it to 0.26.0 or later (NTSCRT > Check for Updates…), then restart Claude." >&2
else
  echo "NTSCRT isn't installed. Download it from https://github.com/finnmckenty/NTSCRT/releases/latest, drag it to Applications, then restart Claude." >&2
fi
exit 1
