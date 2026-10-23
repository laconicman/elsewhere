# GitHub workflow — elsewhere

*Set up 2026-10-23.* It follows devin-kick's model (issues, milestones as the release
plan, tags as versions) and swift-libxray's after it. Every row in *Applied* was applied
and checked live with `gh`.

## Applied — 2026-10-23

| What | State | How |
|---|---|---|
| Merge method | **Merge commits only**: squash and rebase off; atomic, reviewed commits land as they are | repo API |
| Branch hygiene | `delete_branch_on_merge`, `allow_auto_merge` on | repo API |
| Protection | Ruleset `protect main`: `non_fast_forward`, `deletion`, no bypass. Requiring a PR or the CI check is the owner's later call | `gh api repos/laconicman/elsewhere/rulesets` |
| Topics | swift, macos, cli, mcp, xray, vless, proxy, fetch | repo API |
| Vulnerability reporting | Private reporting on; `SECURITY.md` points at it | repo API, `SECURITY.md` |
| Labels | GitHub's `enhancement`, `bug`, `documentation`, plus `breaking`, `upstream`, `tech-debt`, `hygiene`, `tests`, `needs-owner` | `gh label list` |
| Release notes | `.github/release.yml` maps the labels to sections | `.github/release.yml` |
| Milestones | M1 · fetch (no tag — lands in 0.1.0), M2 · serve and wiring — `0.1.0`, M3 · dogfood fixes — `0.2.0`, each described by its done-when | `gh api …/milestones` |
| Issues | #1 live spikes (needs-owner), #2–#6 the TD-1…TD-5 register, #7/#8 the M1 PRs, #9/#10 the M2 surface | `gh issue list` |
| PR template | Local gate, docs touched, labels and milestone, free pass, ledger at 0 | `.github/pull_request_template.md` |
| Reviewer steering | `REVIEW.md` (Devin Review) | `REVIEW.md` |
| Dependabot | SwiftPM + Actions, monthly | `.github/dependabot.yml` |
| CI | `swift build` + `swift test` on GitHub's `xcode-27` image; the 101 MB engine artifact cached keyed on `Package.resolved` | `.github/workflows/ci.yml` |
| Swift Package Index | `.spi.yml` documents `ElsewhereKit`; list the repo after the first semver tag | `.spi.yml` |
| DeepWiki | README badge placeholder; enable once indexed | `README.md` |

## Habits

**Per PR:**
- Branch `feat/…`, `fix/…` or `chore/…`, from `main`.
- Atomic commits that each build.
- `gh pr create --label <one> --milestone "M<n> · …"`.
- The free pass first: DeepWiki, prospectively; plus one `swe-2-max` review through
  `kick`.
- Triage the review round; reply in each thread, and push fixes that make the finding
  false.
- When the reviewer's re-run on the head reads `owed 0 / to re-read 0`, and the owner
  approves: `gh pr merge N --merge --auto`.

**Closing milestone M_n**, done in the PR that completes it and right after it merges.
The milestone is the one source: its title ends in the tag (`0.1.0` for M2, `0.2.0` for
M3 — M1 has no tag of its own) and its description is the done-when. The PR that
completes M_n's features sets `Elsewhere.version` to the tag. Each step runs only if the
one before it succeeded, so a milestone closes only once its release exists.

```bash
number=2                                                  # M2
milestone=repos/laconicman/elsewhere/milestones/$number
title=$(gh api $milestone --jq .title)                    # "M2 · … — 0.1.0"
tag=${title##* — }                                        # "0.1.0": no v prefix (SwiftPM)
done_when=$(gh api $milestone --jq .description)
[[ $tag =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] &&               # a title without a tag stops here
git switch main && git pull --ff-only &&
git tag -a "$tag" -m "$done_when" &&
git push origin "$tag" &&
gh release create "$tag" --verify-tag --generate-notes --title "$tag — ${title% — *}" &&
gh api $milestone -X PATCH -f state=closed
```

**Never:**
- poll CI;
- force-push `main`, which the ruleset refuses anyway;
- commit the owner's config or a real link anywhere — the config lives outside the repo,
  and `git log --all -S vless://` should always come back empty;
- leave a milestone open after its tag.

## Not adopted, and why

| Feature | Why not |
|---|---|
| Squash merges | They would collapse the atomic, reviewed commits that each build |
| Required checks / required PR | Owner's call; CI's first green run comes first |
| Live tests in CI | The suite is offline by contract; `ELSEWHERE_LIVE=1` drills are opt-in and local |
