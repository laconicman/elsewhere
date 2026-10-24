# Design

One decision per section: what was chosen, why, and what was rejected. Consult answers are
`../elsewhere-consults/2026-10-23-c4-swift-libxray-consumer.answer.md` (C4) and
`2026-10-23-c5-xray-core-flat-outbound.answer.md` (C5); the spikes are `spikes.md` (S1–S3)
in the same folder. The megaplan itself lives beside the repo at
`../TASK-code-elsewhere.md` — context, not authority.

## Overview

`elsewhere` is one binary: a CLI today, an MCP server (`serve`) at M2. Under it,
`ElsewhereKit` holds the model — config, exits, the generated Xray config — and the
engine is `XrayCore` from `swift-libxray`, called in-process. This file records why each
piece is shaped the way it is.

## The engine runs in-process, via swift-libxray

Xray-core is linked into the binary through `swift-libxray`'s binary target (the official
XTLS/libXray Apple cgo artifact, re-hosted) — no subprocess, no port to manage beyond the
loopback inbounds we pick. **Why:** a fetch needs to be one tool call; shipping the engine
in-process removes install/start/kill ceremony. **Rejected:** shelling out to an `xray`
binary (a second thing to install and keep compatible), and dima-u's wrappers (a year or
six months behind upstream, per the plan's Appendix B).

## One engine instance; every exit is an inbound

There is one Go runtime per process, so one running engine — and several exits at once are
expressed as **one `mixed` inbound per exit** on 127.0.0.1 plus field routing to each
exit's outbound (C4: two `runXray` instances are unsupported). `fetch --exit NAME` then
just points URLSession at `in:<name>`'s port. Ownership is enforced at process scope:
`TunnelSupervisor` claims the engine when it starts, a second live supervisor's `start`
is refused rather than allowed to stop a core it doesn't own, and `stop` releases only
its own claim — one supervisor per session is still the shape, `serve` (M2) will share
sessions rather than engines. **Rejected:** restarting the engine to
switch exits — slower and loses warm connections; several `XrayCore` instances —
impossible.

## HTTP CONNECT, not SOCKS

The `mixed` inbound speaks both; the client uses HTTP CONNECT — the URLSession gets
`URLSessionConfiguration.proxyConfigurations` carrying a
`ProxyConfiguration(httpCONNECTProxy:)` (Network framework, macOS 14+). **Why:** CONNECT
is explicit about its destination and easy to audit;
SOCKS5 would do the same job. **Rejected:** nothing stronger than "one had to be picked";
the inbound keeps both ears anyway.

## `sockopt.interface` binds every outbound — `direct` included

`XrayConfigBuilder` merges `"interface":"<name>"` into each outbound's
`streamSettings.sockopt` — including `out:direct`. This is what makes `--direct` direct:
while a system tunnel (INCY's utun) owns the default route, sockets bound to `en0` leave
through it (S3 proved it on the live tunnel — bound egress differed). `auto` resolves the
current path's first physical interface at tunnel start via `NWPathMonitor`; if none is
found that is a `doctor` failure and a tunnel-time error, never a quiet unbind (A8 —
rule 5).
**The caveat (C5 §6):** the *connection* is bound; the *hostname lookup* is not — Xray's
freedom outbound resolves through the system resolver. Direct connection, system-path
lookup; accepted for 0.1.0 (TD-4). **Rejected:** per-exit binding (unneeded flexibility)
and `sendThrough` (link-converted outbounds can carry it; it means something else and is
stripped).

## No `dns` block

Routing uses `domainStrategy: AsIs`: hostnames travel to the exit and resolve there — the
exit country resolves the name, which is the point. **Rejected:** a `dns` block would
re-decide what the plan deliberately delegates.

## The engine's log is never a console log

Xray's console logger writes to **stdout**
([`app/log/log_creator.go` at v26.10.21](https://github.com/XTLS/Xray-core/blob/v26.10.21/app/log/log_creator.go)
registers `LogType_Console` with `CreateStdoutLogWriter`, `log.New(os.Stdout, …)` in
`common/log/logger.go`) — and this tool's stdout *is* the payload (a fetched page on the
CLI) or the protocol (MCP stdio). So the generated config is `"log":{"access":"none",
"loglevel":"none"}` by default, or `{"access":"none","error":"<path>","loglevel":
"warning"}` when a log path is given — ``XrayConfigBuilder/XrayLog`` is exactly those two
shapes. There is no middle volume and no stderr route (swift-libxray TD-6, here TD-3).
**Rejected:** defaulting to a file under `~/Library/Logs` — silent is the honest default
for a tool whose output is consumed by agents; `serve` picks the file shape because a
server's operator has no stdout to read (see "`serve` keeps one engine with every lane,
lazily").

## Flat and classic outbound shapes both accepted

`convertShareLinks` returns this core's **flat** outbound (`settings:{address,port,id,
encryption}`); a pasted full config usually carries the classic `vnext`/`servers` shape.
The loader accepts both (C5 §1–2): `.xray` exits unwrap `{"outbounds":[<one>]}`, and the
generated config splices whatever shape arrived — `doctor` proves it by running the
assembled config through `XrayCore.test`. **Rejected:** converting classic → flat
ourselves (re-implementing the engine's conversion) and rejecting the classic shape (INCY
exports it).

## `test` validates; `run` is the only binder

`XrayCore.test(configJSON:)` binds no sockets (C5 §3), so `doctor` — and `exits add`'s
"validate before save" — can validate freely without touching the network. A taken
candidate port is a `run`-time failure: the instance then sits in an unknown state
(C4 §2, C5 §5), so PR #2's `TunnelSupervisor` policy is defensive `stop`, fresh
`freePorts`, one retry. Lifecycle edges (`run` while running, `test` while running,
`stop` when stopped) are unpinned upstream until swift-libxray 0.2.0 — guarded with
`isRunning` meanwhile (TD-5).

## The CLI starts only the lanes it needs

`fetch --exit moldova` brings up `moldova`'s lane and nothing else; `--direct` brings
up only `out:direct`; `whoami --all` is the one call that wants every lane, so it
starts them all on one engine (A9). A `proxy` exit is a `Route.external` — URLSession
talks to that proxy directly and the engine never starts at all. `TunnelSession.open`
is where names become routes. **Rejected:** always starting every lane (slower, and a
broken exit would poison unrelated fetches) and a warm-up probe (A7 — the fetch itself
is the probe; `serve` does not warm up either).

## stdout is the payload; metadata is stderr or `--json`

`fetch` prints the decoded body and nothing else on stdout — an agent pipes it without
a `sed`. Status lines, truncation and binary notices, and the `HTTP <status>` note go
to stderr; `--json` replaces the body with the whole result object when a caller wants
structure. Printed URLs — the JSON fields, the redirect list, the stderr note — keep
scheme, host, path and query but never userinfo, and so do URL-shaped header values
(`Location`, `Link`): where a request went is data, a credential in it is not. HTTP ≥ 400 is a *result* — the command exits 0 — because
the status is data
the agent reads (§5.5). **Rejected:** stderr-and-no-body on errors (loses the page's
own error body) and a JSON envelope by default (most calls want the page).

## The private-address guard judges literals, not names

`fetch` refuses private/local destinations unless `--allow-private` — the tool reaches
everywhere the tunnel does, so a mistyped URL must never be the way something reads
`169.254.169.254`. Every redirect hop is re-checked, and a refused hop becomes the
thrown error rather than the pre-hop 3xx. Hostnames are **not** resolved locally: a
name's address depends on *where* it resolves, and the exit resolves it — refusing a
public hostname that happens to land on a LAN address here would answer the wrong
question. Only what can be judged is refused: `localhost`/`*.localhost` and IP literals
(v4 ranges; v6 `::`, `::1`, `fc00::/7`, `fe80::/10`; `::ffff:v4` judged by the
embedded v4). The reference MCP fetch server has the same shape.

## `run` exports a proxy environment, not a sandbox

`run -- CMD` sets `HTTP_PROXY`/`HTTPS_PROXY` to `http://127.0.0.1:PORT` and
`ALL_PROXY` to `socks5h://127.0.0.1:PORT` — the `mixed` inbound speaks SOCKS5, and
the `h` keeps DNS remote (the exit resolves, not the LAN). `NO_PROXY` is the
parent's bypass list plus loopback — an internal host the parent keeps off a
proxy stays off ours, which could not resolve it anyway;
everything lands in upper and lower case because tools disagree on which they read. A
`proxy` exit passes its configured URL through. The child inherits stdio and its
status is ours — 128 + signal on a signal death (unless the parent itself was
signalled: then the signal rule below sets the status, whatever the child
reported) — and the parent ignores
SIGINT/SIGTERM while it lives: the terminal already delivered them to the whole
foreground group, so the child gets its own copy and the parent must outlive it to
stop the tunnel. A `proxy` exit's configured URL — credentials included — is exported
to the child's environment verbatim; the child needs it to authenticate, and that is
the contract, said plainly. Task cancellation is forwarded to the child — `terminate()` (SIGTERM)
first, a `SIGKILL` five seconds later if it still stands — and the reaped status
(143/137) flows back like any other exit. **Rejected:** per-app routing machinery
(pf, a transparent proxy) —
heavier than the contract needs.

## `Renderer` walks SwiftSoup's DOM; escaping stays minimal

`fetch --format markdown` renders HTML to Markdown for the agent's eyes. The field
of Swift HTML→Markdown libraries is tiny — the plan's survey (§3.7) found every
candidate at ≤ 18★ and unmaintained — so the renderer is a hand-written walk
over **SwiftSoup**, the long-lived jsoup port already trusted for parsing, and
the block/inline rules are ours to tune (TD-6). The reader is a language model,
which shapes two decisions. **Escaping is minimal:** only a line that would
open a block — heading, bullet, quote, numbered marker, fence, rule, HTML
opener or link reference definition — `|` in table cells, and `[`/`]` — and a
backslash — inside a link or image label get a backslash; an inline element's
edge whitespace moves outside
its delimiters. Over-escaping hurts an agent's readability more than the rare
literal marker it prevents. **The JavaScript-shell note is honest:** when a page carried
`script[src]`s but renders under 200 characters, `fetch` appends
`_Note: this page appears to be rendered by JavaScript; the HTML shell carried
little content._` — a shell pretending to be content is worse than a named limit.
**Links are allowlisted:** only `http`, `https` and `mailto` destinations become
`[text](…)` — a page can carry someone's share link as content, but the Markdown
output never turns a non-web scheme into an actionable link; an `img` whose
`src` is not http(s) renders as its alt. Rendering applies only to what
`TextDecoder` calls text: a trace body or a JSON
document's decoded text passes through unchanged for every format — only `raw`
is wire-exact. The content sniff — `looksLikeHTML` judging the body's opening
when no Content-Type arrived — is defensive: a nil Content-Type never reaches
the renderer in today's fetch path. Fixtures
are captured pages, one per shape — a GitHub README, a Wikipedia article, an Apple
Documentation SPA shell — plus a hand-written `constructs.html` carrying every
construct; provenance and licences live in
`Tests/ElsewhereKitTests/Fixtures/html/SOURCES.md`, and goldens are the renderer's
own output, frozen after a read (`ELSEWHERE_WRITE_GOLDENS=1` regenerates).

## `Pager` pages in characters, with a continue marker

`--max-length`/`--start-index` mirror the reference MCP fetch tool's
`max_length`/`start_index`: a cut is in `Character`s — an emoji or a combining
sequence is never split — and a page that leaves a remainder ends with
`<elsewhere:truncated next_start_index=N total=T>`. `startIndex` past the end
returns the marker alone (nothing more to read is information, not an error), and
the CLI default of 0 means unlimited while M2's tool gets the agent-friendly 5000.
The marker and the `Source:` footer are plain text a fetched page could imitate —
accepted: the reader is an agent, and `--json` is the machine-readable channel
when the distinction matters.

## Signals cancel the work; the exit is 128 + the signal

SIGINT/SIGTERM are dispatch-sourced (`signal(sig, SIG_IGN)` first, then
`DispatchSourceSignal` — Domicile's `SignalSource` shape, copied), cancel the
command's work task, and exit 128 + the signal number once the session has closed —
the code a shell expects, after a polite stop of the Go runtime.

## No protocol allowlist — the engine validates

`XrayConfigBuilder` requires a `protocol` string and nothing more: `test` reports an
unknown protocol with Xray's own message (a plan amendment — A2). An allowlist of
{vless,vmess,trojan,shadowsocks,socks} would only block legitimate outbounds such as
wireguard. **Rejected:** the allowlist itself.

## Config file + environment, with that precedence

`--config` > `ELSEWHERE_CONFIG` > `~/Library/Application Support/elsewhere/config.json`
(0700/0600 — it carries secrets). `ELSEWHERE_LINK` short-circuits: one link synthesizes
an in-memory `env` exit and the file is never read — the ad-hoc path for agents.
`direct` is implicit and always present; `env` is synthesized, never stored — both names
are reserved. **Rejected:** CLI-only link flags for the common case (the link in shell
history), and a default-on `direct` exit row in the file (it's code, not config).

Scrubbing inverts the enumeration too: for error text, every string leaf under an
unknown key counts as a secret (≥ 4 chars) — only `Redactor`'s `publicKeys` allowlist
of structural values stays collectible-free. Display redaction keeps the key-based
`secretKeys` list; the two paths answer different questions.

## Exit names are routing tags

A name must match `^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$` — DNS-label-shaped: the
alphabet without dots, and no leading or trailing dash — because it becomes the
inbound tag `in:<name>` and a CLI argument. Reserved: `direct`, `env`.

## Exit statuses are a contract

BSD `sysexits(3)`: 0 done, 1 fetch error or a doctor failure, 64 usage, 69
engine/tunnel unavailable, 77 the private-address guard refused, 78 config. The table is
one source — ``ExitStatus/rows`` — pinned against the README and `--help` by a test.

## The User-Agent is Chrome's — the owner's call

Fetches send the current Chrome-on-macOS UA string (one named constant, hand-bumped per
release — TD-1). The owner: *"when AI is acting on my behalf … the agent could tell me
to fetch the page with a browser from the other network; this would be just the same,
but much more dumb."* The header only — no JA3/TLS fingerprint spoofing, no CAPTCHA
solving. **Rejected:** an honest `Elsewhere/x.y` default (the owner chose otherwise; a
custom string is one config key away).

## English only, no localization

The consumer is an agent; every message is English source text. **Rejected:**
`.xcstrings` — overhead for an audience of one language (D11).

## Two repositories

`swift-libxray` is the reusable engine package; `elsewhere` is the tool. **Why split:**
the engine has its own release cadence (upstream asset bumps) and consumers beyond this
tool; coupling them would pin the engine's semver to the tool's. **Rejected:** a monorepo
target (the artifact's provenance records deserve their own review surface — they got
one, on PR #4).

## `serve` keeps one engine with every lane, lazily

`elsewhere serve` holds **one** ``TunnelSession`` behind the three tools, opened on the
first call that needs a route — with every Xray lane *and* `direct`, so switching exits
never restarts the core. Where the CLI opens only the lanes a call needs (A9), a server
pays one Go start and reuses it across calls and exits. The config is re-read per call:
when an exit changed — added, removed or edited — or the bind interface did, and
nothing is in flight, the session is reopened on that call; while a call runs, the
current session serves and a name the file just gained gets the Kit's `.exit` — the
next call picks it up. A dead engine (``TunnelSession/isAlive`` false) reopens the same
way, and a failed start backs off 1 s doubling to 30 s — a call inside the window is
refused without a new attempt. The SDK runs tool calls concurrently (C6), so that
decision — reuse, reopen or refuse — is taken one call at a time: a call arriving
mid-decision waits for it and decides on the state it left. The engine stops after
`--idle-stop` minutes of no calls (default 10, `0` = never), counted from the last call's
end — never while a call is in flight — and restarts on demand. There is no warm-up probe
(A7 holds: the fetch is the probe; `elsewhere_whoami` is the probe when wanted). stdout
is the protocol, so the engine log defaults to a file —
`~/Library/Logs/elsewhere/xray.log`, in a 0700 directory at 0600 — when neither
`--xray-log` nor `ELSEWHERE_XRAY_LOG` is given, and `--log-tsv` keeps an audit row per
call and per lifecycle edge. **Rejected:** a session per call — a cold Go start per
fetch — and a warm-up probe, which spends a request proving what the first real call
proves anyway.

The tool inputs are the reference MCP fetch tool's plus `exit`: `elsewhere_fetch`
takes `url`, `exit`, `max_length` (5000, at most 200000), `start_index` and `raw`;
`elsewhere_whoami` takes `exit`; `elsewhere_exits` takes nothing. `--allow-private`
is a *serve* flag applied to every fetch/whoami in the process, never a tool
argument — a fetched page is untrusted text, and no page may talk a model into
fetching the LAN. Each description carries the "what an exit is" legend, because a
host may load one tool's description and never another.

## No `elsewhere_run` tool

The CLI's `run -- CMD` has no MCP counterpart. Every host that could call such a tool
already has a shell, where `elsewhere run -- …` does the same under the host's own
command approval. A tool that executes arbitrary commands with a proxy environment
would widen the server's surface — a page fetched through `elsewhere_fetch` is
untrusted text that can steer a model, and the step after reading it must not be able
to be "run this" — and would make the server's read-only annotations false. The three
tools are read-only and idempotent; the only side effect is the engine's own
lifecycle. If a host without a shell ever needs it, it belongs in a separate tool
profile, off by default, with an allowlist of commands (devin-kick's profile
pattern) — not in the default server.

## Registration surfaces are thin pointers to one binary

Every host registration — the Claude Desktop `.mcpb`, the Claude Code plugin, the Devin
Desktop entry, the generic stdio snippet — points at one `elsewhere` binary the owner
built and placed on a stable path; none bundles it. **Why:** a compiled Swift binary is
per-architecture and, embedded in a `.mcpb`, frozen inside Desktop's private extension
folder — invisible to the other hosts and stale the moment the owner rebuilds. One
binary, symlinked into `~/.local/bin` (no sudo) or `/usr/local/bin`, serves every host and
follows each `swift build -c release`. The surfaces carry only what a host cannot discover
at runtime — the path and `serve`'s flags; the tools are listed live (`tools_generated`).
Hosts write their configs in JSON, which no shell expands, so the path options and
variables (`--config`/`ELSEWHERE_CONFIG`, `--xray-log`/`ELSEWHERE_XRAY_LOG`, `--log-tsv`)
expand a leading `~` themselves (C7). The `elsewhere` skill ("try Elsewhere first") gives
an agent the route the inaccessible-sources rule lacks: a step 0 before inferring or
asking. **Rejected:** bundling the binary in the `.mcpb` (deepwiki-mcp's precedent and
reasoning); a Homebrew formula (a tap for an audience of one); `ELSEWHERE_LINK` in a host
config — the secret would sit in plain text beside other servers' settings, where
`exits add --link -` keeps it in the 0600 file.

## See Also

- <doc:Roadmap>
- <doc:TechDebt>
