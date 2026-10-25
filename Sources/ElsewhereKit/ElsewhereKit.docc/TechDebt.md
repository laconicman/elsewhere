# TechDebt

Numbered register of known compromises. Code references an item as `TODO(TD-n)` or in
prose `(TD-n)`.

## Overview

Each item states its **Cost** (what it hurts today) and **Discharge** (the change that
retires it). Status: **open** or **discharged**; ids are never reused.

### TD-1 — the Chrome User-Agent string is hand-bumped — *open*, [#2](https://github.com/laconicman/elsewhere/issues/2)

`UserAgent.chromeString` is a hand-picked Chrome-on-macOS UA (the reduction freeze pins
the build to `0.0.0`, so only the major version moves).

**Cost:** it drifts stale as Chrome ships majors — a year's-old UA stands out.
**Discharge:** bump the constant each release (it is one named constant on purpose);
mechanising it (scraping chromereleases at build time) is worse than the debt.

### TD-2 — `freePorts` are candidates, not reservations — *discharged*, [#3](https://github.com/laconicman/elsewhere/issues/3)

The inbound ports come from `XrayCore.freePorts`, which checks-now/uses-later: between
the check and `run` a port can be taken, and a taken port fails `run` mid-start with the
instance in an unknown state (C5 §5).

**Cost:** a rare, timing-dependent start failure.
**Discharge:** discharged by `TunnelSupervisor`'s policy — defensive `stop`, fresh
candidates, one retry — in `86d4f23` (`FEAT: TunnelSupervisor and TunnelSession`),
pinned by `aTakenCandidateRetriesWithFreshPorts`: the first draw is deliberately squat
on and the second draw wins.

### TD-3 — the engine log has no API hook — *open*, [#4](https://github.com/laconicman/elsewhere/issues/4)

Xray's console logger writes to **stdout** and the JSON API offers no log callback
(upstream: swift-libxray TD-6). ``XrayConfigBuilder/XrayLog`` is therefore only two
shapes — fully silent, or warning-level to a file.

**Cost:** no middle volume; `doctor`/`fetch` diagnostics cannot surface engine detail
without a file. Parse-time deprecation warnings bypass the configured logger entirely
and reach fd 1 — absorbed by ``OwnStdout`` (the process's own stdout), which is why
that type exists. The engine log is the one deliberately unredacted surface: it is
the engine's own output, which Elsewhere cannot filter (no hook), and it lives 0600
in a 0700 directory like the config whose secrets it could at worst echo. A
pre-existing `--xray-log` file keeps whatever mode it has — the path is the user's
choice; only files Elsewhere creates are 0600 (serve's default also sits in a 0700
directory).
**Discharge:** upstream grows a log hook; until then `.silent` is the default and
`.file` covers debugging.

### TD-4 — direct-path DNS is not bound to the interface — *open*, [#5](https://github.com/laconicman/elsewhere/issues/5)

`sockopt.interface` binds the *connection*; the freedom outbound resolves the CONNECT
hostname through the unbound system resolver (C5 §6). With a system VPN up, a `--direct`
connection is direct but its lookup follows the system path.

**Cost:** the tunnel sees the hostname, not the traffic; a lookup that fails inside the
tunnel fails `--direct` too.
**Discharge:** an Xray `dns` block or an interface-bound resolver — only if it ever
matters in practice (recorded, not scheduled).

### TD-5 — XrayCore lifecycle edges are unpinned — *open*, [#6](https://github.com/laconicman/elsewhere/issues/6)

`run` while running, `test(configJSON:)` while running, `stop` when already stopped —
the behaviour at these edges is asserted nowhere in swift-libxray 0.1.0 (planned for its
0.2.0 milestone).

**Cost:** the Kit guards every call with `isRunning` and a defensive `stop` rather than
relying on a contract; a wrong edge is discovered at runtime.
**Discharge:** swift-libxray 0.2.0 pins the edges with tests; the guards stay as
defense-in-depth.

### TD-6 — renderer quality is fixture-driven — *open*, [#8](https://github.com/laconicman/elsewhere/issues/8)

`Renderer` was tuned against the five fixtures in `Tests/ElsewhereKitTests/Fixtures/html`
— real pages carry shapes they do not (Wikipedia's hatnotes and infobox spans, for
instance, already render with cosmetic gaps).

**Cost:** odd Markdown on pages unlike the fixtures; an agent gets the content but
occasionally with flattened or awkward blocks.
**Discharge:** real-world pages feed new fixtures, the block/inline rules iterate in
M3's dogfood pass, and each fix lands with a golden.

### TD-7 — the body is read byte by byte — *open*, [#14](https://github.com/laconicman/elsewhere/issues/14)

`Fetcher` consumes `session.bytes(for:)`'s `AsyncBytes` one `UInt8` at a time so the
5 MB cap can cut mid-stream. Measured 2026-10-24: the 5.6 MB loopback body through a
live engine lane completes in ~0.6 s (~9 MB/s) — fine for 0.1.0.

**Cost:** per-byte iteration is roughly an order of magnitude slower than a
`dataTask` delegate buffer; it shows only on multi-MB responses.
**Discharge:** rewrite the read path as a `URLSessionDataDelegate` accumulating
`Data` chunks if the measurement ever says it matters — it does not yet.

### TD-8 — the `.mcpb` binary path is fixed to `~/.local/bin/elsewhere` — *open*, [#18](https://github.com/laconicman/elsewhere/issues/18)

The Desktop bundle launches `${HOME}/.local/bin/elsewhere` directly rather than offering the
path as a `user_config` option: Claude Desktop substitutes `${HOME}` in `mcp_config` but not
inside a `user_config` default ([mcpb#251](https://github.com/modelcontextprotocol/mcpb/issues/251)),
and its install form would not accept an empty optional field (observed 2026-10-24) — so the
bundle offers one required knob, the idle minutes, and the engine log stays at `serve`'s default.
The mechanism, read in Desktop's launcher: `mcp_config` is substituted in one ordered pass —
`HOME` before `user_config.*` — so a `${HOME}` that arrives through a user value is never
expanded, and the executable check runs on the resolved `command`, not `entry_point`.

**Cost:** a Desktop user whose binary lives elsewhere edits the manifest and re-packs instead
of typing a path at install time.
**Discharge:** mcpb#251 fixed upstream → restore the `binary_path` option with that default and
point `command`/`entry_point` back at `${user_config.binary_path}`.

## See Also

- <doc:Design>
- <doc:Roadmap>
