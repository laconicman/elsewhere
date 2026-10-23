# elsewhere

<!-- TODO(SPI): enable the Swift Package Index badge once the repo is listed.
[![Swift Package Index](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Flaconicman%2Felsewhere%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/laconicman/elsewhere)
-->
[![CI](https://github.com/laconicman/elsewhere/actions/workflows/ci.yml/badge.svg)](https://github.com/laconicman/elsewhere/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache_2.0-blue.svg)](LICENSE.txt)
<!-- TODO(DeepWiki): uncomment once the repo is indexed.
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/laconicman/elsewhere)
-->

Fetch it from elsewhere: a macOS CLI and MCP server that reads URLs through its own VLESS/Xray tunnel — so an agent can read an "unreachable" page instead of inferring it.

**The failure mode it fixes.** With the system VPN connected, foreign sites work but
RU-only services and sites that refuse datacenter/VPN ranges fail; with it off,
blocked foreign sites fail. Faced with either, the agent infers the page's contents or
hands you fetch instructions — both cost you hours. `elsewhere` brings its own tunnel:
`elsewhere fetch URL` runs Xray-core *in-process* (the official
[XTLS/libXray](https://github.com/XTLS/libXray) Apple build, via
[swift-libxray](https://github.com/laconicman/swift-libxray)) from a stored `vless://`
exit and returns the page as Markdown — one tool call, not a conversation. `--direct`
is a genuinely direct path: the engine's sockets bind the physical interface, so they
bypass the system tunnel that owns the default route.

## Status

**M1 (fetch) in progress** — this build has the config model, `exits` and `doctor`;
`fetch`/`whoami`/`run` land next, `serve` (MCP) with M2. The first tag, `0.1.0`, is cut
when M2 (`serve`) lands; M1 has no tag.

## Requirements

Xcode 27 (Swift 6.4 tools) and macOS 15.

## Install

```sh
git clone https://github.com/laconicman/elsewhere
cd elsewhere
swift build -c release
install .build/release/elsewhere /usr/local/bin/elsewhere
```

## Configure

Exits are named (`elsewhere exits …`) and live in the config file; a link resolves
through the engine *before* it is saved, so a typo fails at `add`, not at fetch time.
`--link -` reads the link from stdin so it never enters shell history:

```sh
elsewhere exits add moldova --link -    # paste the vless://… link, Enter
elsewhere exits add incy --proxy http://127.0.0.1:10808   # reuse a local proxy as an exit
elsewhere exits add manual --xray outbound.json           # a raw Xray outbound object
elsewhere exits list
```

The first exit added becomes the default; `elsewhere exits default NAME` moves it.
`elsewhere doctor` checks the whole chain — engine version, config permissions, every
exit's conversion, the interface binding, port candidates, and the generated config
through the engine's own validator:

```sh
elsewhere doctor    # [ok]/[info]/[warn]/[FAIL] lines; exit 1 on any failure
```

### The config file

`~/Library/Application Support/elsewhere/config.json`, directory 0700, file 0600 — it
holds the secrets. Hand-editable; a redacted shape:

```json
{
    "bindInterface" : "auto",
    "default" : "moldova",
    "exits" : {
        "moldova" : { "link" : "vless://<uuid>@<host>:<port>?security=reality&type=xhttp…" },
        "incy" : { "proxy" : "http://127.0.0.1:10808" },
        "manual" : { "xray" : { "protocol" : "vless", "settings" : { } } }
    },
    "userAgent" : "chrome",
    "version" : 1
}
```

- `bindInterface`: `"auto"` (default — the current path's first physical interface),
  an interface name, or `"none"`. Applied to *every* outbound, including `direct`.
- `userAgent`: `"chrome"` (default) or a literal string.

### Environment

| Variable | Effect |
|---|---|
| `ELSEWHERE_CONFIG` | Config path (the `--config` flag beats it). |
| `ELSEWHERE_LINK` | A single `vless://…` link; synthesizes one in-memory exit named `env` and ignores the file entirely. |

## Exit status

Stable — scripts may rely on it (BSD `sysexits(3)` values):

| Code | Meaning |
|---|---|
| 0 | done |
| 1 | failed: a fetch error, or doctor found a failure |
| 64 | usage error |
| 69 | the engine or tunnel is unavailable |
| 77 | the private-address guard refused the destination |
| 78 | configuration error |

## The User-Agent, and why it is Chrome's

Fetches identify as Chrome on macOS — the owner's call: *"when AI is acting on my
behalf … the agent could tell me to fetch the page with a browser from the other
network; this would be just the same, but much more dumb."* The header only — no JA3
or TLS fingerprint spoofing, no CAPTCHA solving. `userAgent` in the config (or, from
M1's fetch PR, `--user-agent`) overrides.

## Versioning

`0.x.y` tags, no `v` prefix. `Elsewhere.version` becomes the tag the milestone closes
into.

## Docs

Direction docs live in the DocC catalog and render on the Swift Package Index:
[Design](https://swiftpackageindex.com/laconicman/elsewhere/documentation/elsewherekit/design) —
every decision with its rejected alternative ·
[Roadmap](https://swiftpackageindex.com/laconicman/elsewhere/documentation/elsewherekit/roadmap) ·
[TechDebt](https://swiftpackageindex.com/laconicman/elsewhere/documentation/elsewherekit/techdebt).
