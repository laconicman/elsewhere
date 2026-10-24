# Elsewhere — Claude Desktop extension (`.mcpb`)

A **thin** MCP bundle for Claude Desktop: it carries the manifest only, not the
`elsewhere` binary. Installing it registers the `elsewhere_*` tools with Desktop
and points them at an `elsewhere` executable you build from source.

## Why the binary is not bundled

A compiled Swift binary is per-architecture, and — decisively — a copy embedded in
a `.mcpb` is frozen into Desktop's private extension folder: invisible to your
other hosts (Claude Code, Devin Desktop, other MCP clients) and stale the moment
you rebuild. Pointing at an externally built binary instead gives you **one**
binary on the machine, shared by every host, that stays current with each
`swift build -c release` (via a symlink on a stable path). See
[`../SETUP.md`](../SETUP.md) for the build-and-place steps.

`.mcpb` is a Claude *Desktop* format — Desktop has no Linux build, and `elsewhere`
is macOS-only anyway, so `darwin` is the only platform the manifest claims.

## Build the bundle

```bash
./build.sh          # validates the manifest and writes ../elsewhere.mcpb
```

(The script just runs `mcpb pack`. The `.mcpb` is a build artifact and is
git-ignored.)

## Install & verify

1. Claude Desktop → **Settings → Extensions** → drag `elsewhere.mcpb` in (or
   **Install Extension…**).
2. When prompted, set **elsewhere binary** to your executable's path (default
   `~/.local/bin/elsewhere`); optionally set the idle minutes and the engine log
   file.
3. Verify: the tools icon lists `elsewhere_fetch`, `elsewhere_whoami`,
   `elsewhere_exits`, or ask Desktop *"what elsewhere tools do you have?"*. Logs:
   `~/Library/Logs/Claude/mcp-server-elsewhere.log`.

Because tools are runtime-discovered (`tools_generated`), rebuilding the binary
with new tools/args needs no re-pack — only a fixed binary *path* lives in the
manifest.
