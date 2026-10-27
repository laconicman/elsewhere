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

**0.1.0 — M2 complete**: config model, `exits`, `doctor`,
`fetch`/`whoami`/`run` with Markdown rendering and paging, and `elsewhere serve`, the
MCP stdio server; registration recipes for Claude Code, Claude Desktop (`.mcpb`),
Devin Desktop and any stdio host are in [SETUP.md](SETUP.md).

## Requirements

Xcode 27 (Swift 6.4 tools) and macOS 15.

## Install

```sh
git clone https://github.com/laconicman/elsewhere
cd elsewhere
swift build -c release
mkdir -p ~/.local/bin && ln -sf "$PWD/.build/release/elsewhere" ~/.local/bin/elsewhere
command -v elsewhere || { echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && exec zsh; }
```

The symlink follows every later release build; `/usr/local/bin` with `sudo` works too.
[SETUP.md](SETUP.md) has the full build-and-register recipe.

## Configure

Exits are named (`elsewhere exits …`) and live in the config file; a link resolves
through the engine *before* it is saved, so a typo fails at `add`, not at fetch time.
`--link -` reads the link from stdin so it never enters shell history:

```sh
elsewhere exits add moldova --link -    # paste the vless://… link, Enter
elsewhere exits add incy --proxy http://127.0.0.1:10808   # reuse a local proxy as an exit
elsewhere exits add manual --xray outbound.json           # a raw outbound, or a whole client config with one proxy
elsewhere exits list
```

The first exit added becomes the default; `elsewhere exits default NAME` moves it.
`elsewhere doctor` checks the whole chain — engine version, config permissions, every
exit's conversion, the interface binding, the system resolver (a tunnel-owned,
fake-IP-style resolver warns), port candidates, and the generated config
through the engine's own validator:

```sh
elsewhere doctor    # [ok]/[info]/[warn]/[FAIL] lines; exit 1 on any failure
```

## Use it

```sh
elsewhere fetch https://example.com/ --exit moldova  # the page body on stdout
elsewhere whoami --all                               # ip/loc per exit, direct last
elsewhere run --exit moldova -- git clone https://…  # HTTP(S)_/ALL_PROXY exported
```

`fetch` writes the decoded body to stdout and *everything else* to stderr — status
lines, truncation and binary notices, the `HTTP <status>` note. `--json` prints the
whole result object instead; `--head` prints status and headers; `--output FILE`
saves the raw body. Defaults: GET, up to 10 redirects (each hop re-checked by the
private-address guard; `--no-redirects` returns the 3xx itself — its `Location`
header says where it pointed), a 25 s timeout that bounds the *whole* fetch — a body that
trickles a byte at a time still hits it — a 5 MB body cap, and a Chrome User-Agent
(`--user-agent` overrides). HTTP ≥ 400 is a *result*, not a failure — exit stays 0;
the status is data the agent reads. Private/local destinations are refused unless
`--allow-private` — the tool reaches everywhere the tunnel does, so a mistyped URL
must never be the way something reads a LAN or link-local address.

### Output: Markdown, text, raw — and paging

`fetch --format markdown` (the default) renders HTML to Markdown: a `# <title>`
heading when the page has one, the `<main>`/`article`/`[role=main]` region (nav,
headers, footers, scripts, hidden elements are gone), and a `Source: <final URL>`
footer. `--format text` runs the same pipeline without the markers — links become
their text, images their alt text. `--format raw` writes the response **bytes**
verbatim — no decode, render or paging (a 1251 page stays 1251); `--json` still
carries the decoded text in `body`, since JSON cannot carry bytes. Anything
that is not HTML — JSON, a `cdn-cgi/trace` body — passes through unchanged for
every format. `--head` and `--output` ignore `--format`.

`--max-length N` cuts the rendered text at N **characters** (0 = unlimited, the CLI
default) and ends a cut page with
`<elsewhere:truncated next_start_index=M total=T>`; `--start-index M` reads on from
there. Cuts never split an emoji or a combining sequence — the unit is the
`Character`, not the byte. Both flags reject negative values. Paging applies to
rendered text; raw is the bytes.

Known limitation: a JavaScript SPA's HTML shell carries little content — when a
page had external scripts but renders under 200 characters, `fetch` appends
`_Note: this page appears to be rendered by JavaScript; the HTML shell carried
little content._` rather than pretending the shell was the page.

`--via-system` unbinds the engine's outbound sockets so they ride the system path —
the system VPN when one is up — name lookups included. `--xray-log PATH` (or `ELSEWHERE_XRAY_LOG`) writes the
engine's warnings to a file; silent by default, since Xray's console log is stdout
and stdout here is the payload. `run`'s child gets `HTTP_PROXY`/`HTTPS_PROXY` at
`http://127.0.0.1:PORT` and `ALL_PROXY` at `socks5h://127.0.0.1:PORT` (the `h` keeps
DNS remote) for a tunnel lane — or the exit's own URL for a `proxy` exit, credentials
included: the child needs them to authenticate, and they are exported verbatim — plus
`NO_PROXY` — the parent's own bypass list with loopback added — in upper and
lower case.

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
- `directDNS`: the DoH servers `direct` resolves through — `https://<ip>/path`
  URLs (an IP literal needs no bootstrap lookup; a hostname would fall back to
  the system resolver). Unset means the built-in list: Cloudflare, Google, Quad9
  (an IPv4 and an IPv6 each), then Yandex last. A bound `direct` fails loudly
  when the lookup fails — it never asks the system resolver, which a tunnel
  may own; `--via-system` unbinds the lookup too.
- `userAgent`: `"chrome"` (default) or a literal string.
- Exit names match `^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$` — DNS-label-shaped, so never
  a leading or trailing dash — and `direct`/`env` are reserved.

### Environment

| Variable | Effect |
|---|---|
| `ELSEWHERE_CONFIG` | Config path (the `--config` flag beats it); a leading `~` is expanded. |
| `ELSEWHERE_LINK` | A single `vless://…` link; synthesizes one in-memory exit named `env` and ignores the file entirely. |
| `ELSEWHERE_XRAY_LOG` | Path for the engine's warnings; `--xray-log` beats it, silent is the default; a leading `~` is expanded. |

### MCP server (`elsewhere serve`)

An agent calls the server over stdio — three tools, all read-only and idempotent:

| Tool | Input | Output |
|---|---|---|
| `elsewhere_fetch` | `url` (required), `exit?`, `max_length?` (default 5000, at most 200000), `start_index?` (default 0), `raw?` (default false), `follow_redirects?` (default true) | Four header lines — url, status, content-type, exit · elapsed — then the body as Markdown (`raw`: the decoded text without rendering), paged with the `<elsewhere:truncated …>` marker; HTTP ≥ 400 is a result, not an error. `follow_redirects: false` returns the 3xx itself, with a `location:` line |
| `elsewhere_whoami` | `exit?` | `exit NAME: ip <ip> loc <loc>[ colo <colo>]` — every configured exit plus `direct` when `exit` is omitted |
| `elsewhere_exits` | — | The `exits list` lines (credentials redacted) plus `direct` |

The tunnel opens lazily on the first call that needs a route — one engine with every
exit lane plus `direct` — and stops after `--idle-stop MIN` of no calls (default 10;
`0` = never). Flags: `--allow-private` lifts the private-address guard for every
call; `--via-system` unbinds the engine to the system path; `--log-tsv PATH` appends
an audit row per call and per tunnel lifecycle edge; `--xray-log`/`ELSEWHERE_XRAY_LOG`
redirect the engine log — serve's default is `~/Library/Logs/elsewhere/xray.log`,
since stdout is the protocol (fd 1 itself is handed to the engine as a sink — its
parse-time warnings land in the engine log, never in the stream). Registration
recipes for Claude Code, Claude Desktop
(`.mcpb`), Devin Desktop and any stdio host: [SETUP.md](SETUP.md).

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

128 + *n* means the signal — the shell convention, not ours (SIGINT → 130).

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
