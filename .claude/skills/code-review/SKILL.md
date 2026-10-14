---
name: code-review
description: Review a proposed PR against this repository's structure rules and its requirements using two independent reviewers (Standards and Spec). Required before opening a PR in this repository, and available for explicit branch or PR reviews.
---

# Code Review

Adapted from heedly-builder's code-review skill. Standards and Spec reviews stay separate.

## Prepare the review

- Read `CLAUDE.md`, the rules `.ai/rules/index.md` selects for the changed paths, and the `briareus-architecture` skill.
- Before reviewing, finish the changes and run `swift test`, both scheme builds (README's Validation section) and `python3 scripts/check_escape_hatches.py <base>`. All must pass and the ratchet must resolve its base; a skipped check is not a pass.
- Resolve the PR base from the user's instructions, the existing PR or the stack parent; otherwise `origin/main`. Capture `git diff <base-sha>...<head-sha>`, the commit list and the changed files, and give both reviewers the same SHAs.
- All intended changes are committed before a pre-PR review. A review of uncommitted work is provisional.

## Collect the requirements

Use the assigned issue (`gh api repos/okanetsolutions/briareus-swift/issues/NUMBER` and its comments) and the user's accepted clarifications. An explicit user request can serve as the spec. If requirements cannot be recovered, mark Spec as incomplete and ask.

## Run independent reviewers

Spawn two read-only subagents in parallel with fresh context: the repository path, pinned diff command, commits, changed paths and validation results. Neither sees the other's report or the implementer's conclusions. If delegation is unavailable, report the review as incomplete.

**Standards reviewer:** reports violations the diff introduces against `CLAUDE.md` and the matching `.ai/rules`, citing the rule and location. In particular: logic or networking added to a view; a rule written in both apps instead of Core; a component copied rather than reused or promoted (check the catalog); literal colours, radii or font sizes; a view file or body grown past the limits; new Core logic without a `MacTests` test; one app's screen changed without its twin. Naming and taste are advisory unless they break a rule.

**Spec reviewer:** checks each acceptance criterion on every app the feature exists on: behaviour, loading, empty, error and Read-only token states, and unintended scope. Cites the requirement and a concrete failing scenario.

Each finding has file and line, evidence, impact and a classification: blocker (a defect, an unmet criterion or a violation of an exact rule) or advisory.

## Resolve and report

Confirm each blocker against the code before fixing it. Fix confirmed blockers with the smallest sufficient change, rerun the checks, and have the relevant reviewer verify the new diff. Advisory items are fixed only when the user selects them. Open the PR only when both reviews are complete and no confirmed blocker remains, and record the reviewed SHAs, the checks run and the blocker and advisory counts.
