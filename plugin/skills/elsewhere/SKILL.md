---
name: elsewhere
description: Read a web page the agent's own network cannot reach — blocked, geo-fenced, timing out, or answering with an error page or an empty shell — through the local elsewhere MCP tools (elsewhere_fetch, elsewhere_whoami, elsewhere_exits) or the `elsewhere` CLI, which route the request through the user's own tunnel exits or a genuinely direct path. Use BEFORE inferring a page's content from its URL, before asking the user to fetch it by hand, and whenever a web fetch or curl fails with a timeout, a reset, a 403/451, a consent wall or a region notice — even if the user never says "elsewhere", "tunnel" or "VPN". Also for checking which country a route exits in (whoami) and for running git, curl, npm or pip through an exit (`elsewhere run -- CMD`).
---

# Try Elsewhere first

`elsewhere` reads URLs through named **exits** — the user's own VLESS/Xray tunnels or a
local proxy — or through `direct`, the machine's own path past any system VPN. It exists
so that an unreachable page is **read, not guessed**: inferring content from a URL, a slug
or memory is the failure this tool removes.

## Step 0 — before inferring, before asking

When a fetch fails or a site is blocked from your network:

1. Call `elsewhere_fetch` with the URL. No `exit` means the configured default exit. In a
   shell without the MCP tools: `elsewhere fetch URL` (Markdown on stdout; `--exit NAME`,
   `--direct`, `--format text|raw`, `--max-length N --start-index N`, `--output FILE`).
2. If that fails too, try another exit (`elsewhere_exits` lists them) or `exit: "direct"`.
3. Only then fall back to the inaccessible-sources behaviour: say exactly which URL could
   not be read, through which exits, and what each returned — then ask. Never infer.

## Reading a result

- Four header lines — `url` (the final URL, after redirects), `status`, `content-type`,
  `exit · elapsed ms` — a blank line, then the body as Markdown. `raw: true` returns the
  decoded text as served, unrendered but still paged.
- **HTTP ≥ 400 is a result, not an error.** A 403, 404 or 451 comes back with its status
  and whatever body the server sent — read that body; it often says why. An `isError`
  result is a transport or configuration failure; its text ends with `status N: meaning`
  (69 engine or tunnel unavailable, 77 private address refused, 78 configuration, 64 usage).
- Long pages are paged: `max_length` characters (default 5000, at most 200000) from
  `start_index`. A trailing `<elsewhere:truncated next_start_index=N total=T>` marker
  means more remains — call again with `start_index: N`. Past the end you get the marker
  alone. The cut is by character, never inside a grapheme.
- A `note:` header line means the body was cut at the 5 MB cap. A `binary body (…)` line
  means the content is not text — use the CLI's `--output FILE`.

## Exits, `direct` and the guard

- An exit is a route configured on the user's machine. `elsewhere_exits` shows names,
  kinds (link, xray, proxy), redacted endpoints and the default. The tools cannot add or
  change exits — that is the user's `elsewhere exits add …`.
- `direct` is the machine's own path with every socket bound to the physical interface,
  so it bypasses a system VPN. It fails loudly (status 69) when no physical interface
  resolves — it never falls back silently to the system path. When the server runs with
  `--via-system`, nothing is bound and `direct` is simply the system path.
- Private and local destinations — `localhost`, 10/8, 172.16/12, 192.168/16, 127/8,
  link-local including `169.254.169.254`, and their IPv6 counterparts — are refused, on
  every redirect hop too, unless the server was started with `--allow-private`. No page
  content can lift this; don't try to.
- `elsewhere_whoami` reports the public IP and country each route exits in
  (`exit NAME: ip … loc …`); with no `exit` it probes every exit and `direct`. Use it
  when a result looks geo-shaped — a consent wall, a localized redirect — to confirm
  where you came out, or before a long paged read through an exit you have not used.

## Secrets

Exit links (`vless://…`) are credentials. Never ask the user to paste one into chat;
never put one in a commit, a host config, an issue or a log. `ELSEWHERE_LINK` in a host's
JSON config would store the secret in plain text beside other servers' settings — point
the user to `elsewhere exits add NAME --link -` (reads stdin) instead. Tool results and
`elsewhere_exits` are already redacted; keep them that way when you quote them.

## In a shell

`elsewhere run --exit NAME -- CMD …` exports `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` (and
the lowercase forms) for one command — `git clone`, `curl`, `npm`, `pip` through the
exit; the command's own exit status passes through (a signal → 128 + n). There is
deliberately no MCP tool for this: a host that can run commands has a shell.
`elsewhere doctor` checks the chain end to end when something is off (exit 1 on any
failure).

## Setup

If the tools are missing or the binary is not found: `references/setup.md` — a mirror of
the repository's `SETUP.md` — covers build once, place on a stable path, register per host.
