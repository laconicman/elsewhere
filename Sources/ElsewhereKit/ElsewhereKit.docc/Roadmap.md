# Roadmap

Milestones, priority-ordered — each is one GitHub milestone on `laconicman/elsewhere`,
titled with the tag it closes into. Rationale lives in <doc:Design>; the plan record is
`../TASK-code-elsewhere.md` §7.

## M1 · fetch — *in progress*

The first tag, `0.1.0`, is cut when M2 (`serve`) lands; M1 has no tag.

Done when `elsewhere fetch https://1.1.1.1/cdn-cgi/trace` prints `loc=<exit country>`
through the default exit and `--direct` prints the ISP's; `whoami --all` shows both
while INCY is connected; `run -- curl` and `run -- git clone` work through an exit;
`exits`/`doctor` redact; renderer fixtures green.

- **PR #1 (this one):** the Kit model — config, exits, redaction, the generated Xray
  config — plus `exits` and `doctor`, and the house files.
- **PR #2** ([#7](https://github.com/laconicman/elsewhere/issues/7)):
  `TunnelSupervisor` (lifecycle guards, stop + fresh ports + one retry per Design),
  `Fetcher` with the private-address guard, and `fetch`/`whoami`/`run`.
- **PR #3** ([#8](https://github.com/laconicman/elsewhere/issues/8)): `Renderer`
  (HTML → Markdown via SwiftSoup), `Pager` with the truncation marker, saved-page
  fixtures.
- [#1](https://github.com/laconicman/elsewhere/issues/1) the S4/S5 live spikes with the
  owner's config (needs the owner).

## M2 · serve and wiring — 0.1.0

`elsewhere serve`: an MCP stdio server with `elsewhere_fetch`/`elsewhere_whoami`/
`elsewhere_run`, lazy tunnel start and idle stop ([#9](https://github.com/laconicman/elsewhere/issues/9));
registration everywhere the owner runs an agent — Devin Desktop, Claude Code,
Claude Desktop `.mcpb`, the "try Elsewhere first" skill
([#10](https://github.com/laconicman/elsewhere/issues/10)). Then the `0.1.0` tag by the
GitHubWorkflow recipe.

## M3 · dogfood fixes — 0.2.0

Two weeks of real use: pagination ergonomics, renderer gaps, `--obey-robots` if ever
wanted, HEAD/POST if ever needed, exit health in `whoami`, maybe `exits import --incy`.

## M4 · LadaX-macOS plan — *later*

Appendix A of the plan (per-app routing for macOS) promoted to its own megaplan once M2
has shipped and the engine package is proven.

## See Also

- <doc:Design>
- <doc:TechDebt>
