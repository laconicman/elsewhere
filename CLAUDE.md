# elsewhere — fetch it from elsewhere

One macOS binary, `elsewhere`: CLI subcommands (`fetch`, `whoami`, `run`, `exits`,
`doctor`) and, at M2, `elsewhere serve`, an MCP stdio server. It runs Xray-core
in-process via `swift-libxray` and fetches URLs through named exits — or a genuinely
direct path — so an agent reads an "unreachable" page instead of inferring it.

The DocC catalog (`Sources/ElsewhereKit/ElsewhereKit.docc/`) is authoritative for
direction: `Design` (decisions + rejected alternatives) · `Roadmap` (milestones, one
GitHub milestone each) · `TechDebt` (numbered `TD-n` register, each linked to its issue).
The megaplan and consult/spike records live **beside** the repo, not in it:
`../TASK-code-elsewhere.md` and `../elsewhere-consults/`. They are context; when they
disagree with Design, Design wins.

## Architecture

`swift-libxray`'s `XrayCore` (the one Go runtime's actor) → `ElsewhereKit` (the model:
`ElsewhereConfig`, `Exit`, `ConfigStore`, `XrayConfigBuilder`, `ExitResolver`,
`InterfaceResolver`, `LoopbackProbe`, `Doctor`, `Redactor`, `ExitStatus`) → `elsewhere`
(ArgumentParser glue) → `ElsewhereMCP` later (M2). Swift 6.4 tools version, Swift 6
language mode, macOS 15 floor, with the Swift 7 upcoming features on every handwritten
target. Each choice is reasoned in `Design`.

## Rules specific to this repository

1. **`XrayCore` and `ArgumentParser` never appear in the Kit's public API.**
   `InternalImportsByDefault` enforces it; Foundation types that do appear come through an
   explicit `public import`. Engine errors arrive as `ElsewhereError.engine(String)`.
2. **Errors are typed, and exit statuses are a contract.** Kit functions throw
   `ElsewhereError` (`throws(ElsewhereError)`); the `sysexits(3)` table changes only with
   `ExitStatus.rows`, the README's table and `--help`'s text in one PR.
3. **The link is a secret.** A share link carries credentials in cleartext — it is never
   printed, logged, echoed in an error, or returned in a tool result. Every printable
   form passes through `Redactor`; engine messages get `scrub(_:secrets:)`. Tests grep
   output for the synthetic link's secrets.
4. **The config file is 0600 in a 0700 directory** (`~/Library/Application
   Support/elsewhere/config.json`), written atomically; `ELSEWHERE_LINK` synthesizes an
   in-memory `env` exit and never touches the file.
5. **No silent fallback.** `allowFailover` is never true and nothing falls back to a
   direct fetch when an exit fails — a quiet path switch is a leak.
6. **Zero warnings in handwritten targets.**
7. **Tests are offline.** Loopback only — `NWListener` echo servers and invented
   credentials; never a real server or the public internet. Engine-touching suites are
   `.serialized` because the Go runtime is one per process.
8. **Everything lands via PR, with review rounds.** Atomic commits that each build.
   Merges are **merge commits only** (squash and rebase are off). A ruleset blocks
   force-push and deletion of `main`. The recipes are in `docs/GitHubWorkflow.md`.
9. **Free pass before the paid one.** Before a PR: ask DeepWiki prospectively, since a
   feature branch isn't indexed; and run one free `swe-2-max` review session through
   `kick`. A disagreement with a decision recorded in Design is reported to the owner,
   not applied silently.
10. **One public identity, no AI attribution.** Commits only as
    `laconicman <laconicman@icloud.com>`; check `git log --format='%ae %ce' @{u}..` before
    a push. No `Co-Authored-By` trailer, generated-with footer or sign-off in commits, PR
    bodies, comments or tracked files.

## Author's standing preferences

Clarity over brevity. Prefer a vetted SPM when the dependency is smaller than the problem, and say
so when it is not. Cite sources in prose and code comments. DRY, separation of concerns, low
coupling / high cohesion first. Error types conform to `LocalizedError` with a filled
`errorDescription`. Prefer implicit returns wherever the compiler allows. No magic numbers or
strings: give shared values one named home. Claims are verified, not recalled: look vendor
behavior up (DeepWiki, the spec, the docs) before ruling on it.

## Related skills

`swift-package-manager` · `swift-concurrency` · `swift-testing-expert` ·
`software-development-principles` · `swift-file-organization` · `devin-review-rules` ·
`atomic-commits` · `git-branching` · `repo-init` · `mcp-builder` (M2)
