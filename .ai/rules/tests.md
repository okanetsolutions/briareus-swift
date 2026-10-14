---
paths:
  - 'MacTests/**'
  - 'UITests/**'
---

# Tests

## Test behaviour in Core
`MacTests` covers Core: parsing, cache, request bodies, board rows, filters, errands, settings forms, diffs and what a car says. When logic moves out of a view or model into Core, its test comes with it. Group tests by the Core file they cover (`BoardTests` for `Board.swift`).

## No layout or copy assertions
Do not assert view structure, padding, sibling order or font sizes. Do not assert wording that is UI copy; assert structure, identifiers, values flowing through and state transitions. Wording changes must never break a test.

## No live servers
Tests never reach a real Briareus server, GitHub or OpenAI. Feed Core recorded or constructed `JSON`.
