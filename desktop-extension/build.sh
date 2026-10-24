#!/usr/bin/env bash
# Pack the thin Elsewhere Desktop extension (manifest only — no binary; see README.md).
# Writes elsewhere.mcpb next to the repo root. Requires Node (mcpb runs via npx).
set -euo pipefail

cd "$(dirname "$0")"
out="../elsewhere.mcpb"

echo "Packing $out from $(pwd)/manifest.json …"
npx --yes @anthropic-ai/mcpb pack . "$out"

echo
echo "Done: $out"
echo "Install: Claude Desktop → Settings → Extensions → drag it in."
echo "Note: the elsewhere binary is NOT bundled — build it and place it at ~/.local/bin/elsewhere"
echo "      (see ../SETUP.md)."
