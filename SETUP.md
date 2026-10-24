# Setup — build the binary, put it on a stable path, register per host

The one non-portable piece of elsewhere is the compiled `elsewhere` binary;
everything else (the Claude Code plugin, the Desktop `.mcpb`, the Devin Desktop
entry, the generic stdio snippet, the skill) is a thin pointer to it. So setup
is: **build once from source, place on a stable path, then register per host.**
This file is the single source of truth — the `elsewhere` skill carries a mirror
(`plugin/skills/elsewhere/references/setup.md`), and the other docs link here.

> **Delegate it if you like.** Hand a capable AI agent this file and it can run
> the build-and-register dance for you.

## 1. Build

Needs Xcode 27 (Swift 6.4 tools) and macOS 15 — `elsewhere` is macOS-only.

```bash
git clone https://github.com/laconicman/elsewhere
cd elsewhere
swift build -c release
```

The binary lands at `.build/release/elsewhere`.

## 2. Put it on a stable path

One path every host shares, tracking each future `swift build -c release`
without re-copying:

```bash
mkdir -p ~/.local/bin && ln -sf "$PWD/.build/release/elsewhere" ~/.local/bin/elsewhere
```

No sudo. (`sudo ln -sf … /usr/local/bin/elsewhere` works too, if you'd rather a
system path.) The symlink follows every release build in place;
`swift package clean` breaks it until the next build. Keep the directory on
PATH for your own CLI use — the hosts below get the absolute path anyway.

## 3. Configure an exit

```bash
elsewhere exits add NAME --link -   # paste the vless://… link — stdin, never shell history
elsewhere exits add incy --proxy http://127.0.0.1:10808   # reuse a local proxy as an exit
elsewhere doctor                    # end-to-end check; exit 1 on any failure
elsewhere whoami --all              # ip/loc per exit, direct last
```

## 4. Register per host

Same binary, every host:

- **Claude Code** —
  ```bash
  claude mcp add -s user elsewhere -- "$HOME/.local/bin/elsewhere" serve
  ```
  or install the plugin (the server plus the "try Elsewhere first" skill
  together):
  ```bash
  claude plugin marketplace add laconicman/elsewhere
  claude plugin install elsewhere@laconicman
  ```
  The plugin's `.mcp.json` runs the bare `elsewhere` command, so it resolves
  only if `elsewhere` is on Claude Code's PATH — the §2 symlink covers that
  once `~/.local/bin` is on PATH. Verify: `claude mcp list` shows `elsewhere`.

- **Claude Desktop** — build `elsewhere.mcpb` with
  [`desktop-extension/build.sh`](desktop-extension/build.sh), then **Settings →
  Extensions** → drag it in. The installer asks for the binary path (default
  `~/.local/bin/elsewhere`), the idle minutes and an optional engine log file —
  the bundle carries no binary of its own (see
  [`desktop-extension/README.md`](desktop-extension/README.md)). If the tools
  don't appear, fully quit and reopen Desktop.

- **Devin Desktop** — a stanza under `mcpServers` in
  `~/.config/devin/mcp_config.json`, absolute path. The file holds other
  servers' credentials, so it is edited in place and keeps its mode:
  ```bash
  f=~/.config/devin/mcp_config.json
  jq '.mcpServers.elsewhere = {"command": "/Users/you/.local/bin/elsewhere", "args": ["serve"]}' "$f" > "$f.tmp" \
    && jq empty "$f.tmp" && chmod 600 "$f.tmp" && mv "$f.tmp" "$f"
  ```
  then restart Devin Desktop.

- **Any other stdio host** — the same two fields under `mcpServers`:
  ```json
  { "elsewhere": { "command": "/Users/you/.local/bin/elsewhere", "args": ["serve"] } }
  ```

## 5. `serve` flags

- `--idle-stop MIN` — the engine stops after MIN minutes of no calls
  (default 10; `0` = never).
- `--allow-private` — lift the private-address guard for every fetch/whoami.
- `--via-system` — unbind the engine's sockets; every lane rides the system
  path.
- `--log-tsv PATH` — one audit row per call and per tunnel lifecycle edge.
- `--xray-log PATH` / `ELSEWHERE_XRAY_LOG` — the engine's warnings file;
  serve's default is `~/Library/Logs/elsewhere/xray.log` (stdout is the
  protocol).

Every path option expands a leading `~` itself — a host's JSON config gets no
shell expansion.

## 6. Verify from the host

Ask the agent to call `elsewhere_exits`, then `elsewhere_whoami` (with `exit`
set to an exit name to probe one route). If `serve` runs with `--log-tsv PATH`,
the file gains an `up` row when the tunnel opens and `fetch`/`down` rows as
calls happen — the audit trail doubles as the wiring check.

## 7. Secrets

The link never goes into a host config — `ELSEWHERE_LINK` there would store a
credential in plain text beside other servers' settings.
`elsewhere exits add NAME --link -` keeps it in the config file instead: 0600,
in a 0700 directory.

## 8. Update

```bash
git pull && swift build -c release
```

The symlink follows the rebuild, so every host picks the new binary up at once.
The `.mcpb` needs no re-pack unless the manifest changes — the tools are
discovered live.
