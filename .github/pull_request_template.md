## Summary

-

Milestone: M… · Closes #… — or "no tracked issue".

## Checklist

- [ ] Local gate: `swift build` with no warnings in handwritten targets, `swift test` green (CI repeats it; the suite is offline by contract)
- [ ] Atomic commits that each build; no AI attribution in commits, this body or replies
- [ ] `Design.md` / `TechDebt.md` / `Roadmap.md` updated if a recorded decision, debt item or milestone changed
- [ ] No link, UUID or key reaches stdout/stderr/log/error text outside `Redactor`; config writes keep 0700/0600
- [ ] Exit statuses changed → `ExitStatus.rows`, the README table and `--help` all updated
- [ ] Changed public API → `breaking` label, minor bump noted here
- [ ] Labelled for the release notes (`.github/release.yml`) and placed in its milestone
- [ ] Free pass first: DeepWiki asked prospectively (the feature branch isn't indexed) — link it here
- [ ] Before merge: Devin Review round complete, at `owed 0 / to re-read 0`
