#!/usr/bin/env bash
# Package the Claude Desktop extension: dist/ntscrt-mcp-<version>.mcpb.
#
#   ./scripts/make-mcpb.sh 0.26.4
#
# An .mcpb is a zip with manifest.json at its root. Ours carries only a
# launcher (mcpb/server/launch.sh) that starts the installed app's built-in
# server, so it doesn't change between releases except for the version.
# Attach it to the GitHub release; the "MCP Registry" workflow then lists
# that release in the official MCP Registry.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: make-mcpb.sh <version>}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R mcpb/ "$STAGE/"
python3 - "$STAGE/manifest.json" "$VERSION" <<'PY'
import json, sys
p, v = sys.argv[1], sys.argv[2]
m = json.load(open(p)); m["version"] = v
json.dump(m, open(p, "w"), indent=2, ensure_ascii=False)
PY
chmod +x "$STAGE/server/launch.sh"
mkdir -p dist
OUT="$PWD/dist/ntscrt-mcp-$VERSION.mcpb"
rm -f "$OUT"
(cd "$STAGE" && zip -qr -X "$OUT" manifest.json icon.png server)
echo "built: $OUT"
shasum -a 256 "$OUT"
