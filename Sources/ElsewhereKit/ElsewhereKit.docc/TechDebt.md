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

### TD-2 — `freePorts` are candidates, not reservations — *open*, [#3](https://github.com/laconicman/elsewhere/issues/3)

The inbound ports come from `XrayCore.freePorts`, which checks-now/uses-later: between
the check and `run` a port can be taken, and a taken port fails `run` mid-start with the
instance in an unknown state (C5 §5).

**Cost:** a rare, timing-dependent start failure.
**Discharge:** PR #2's `TunnelSupervisor` policy — defensive `stop`, fresh candidates,
one retry — pinned by a test once the lifecycle tests exist.

### TD-3 — the engine log has no API hook — *open*, [#4](https://github.com/laconicman/elsewhere/issues/4)

Xray's console logger writes to **stdout** and the JSON API offers no log callback
(upstream: swift-libxray TD-6). ``XrayConfigBuilder/XrayLog`` is therefore only two
shapes — fully silent, or warning-level to a file.

**Cost:** no middle volume; `doctor`/`fetch` diagnostics cannot surface engine detail
without a file.
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

## See Also

- <doc:Design>
- <doc:Roadmap>
