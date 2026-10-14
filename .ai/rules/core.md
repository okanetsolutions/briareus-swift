---
paths:
  - 'Mac/Core/**'
---

# Core

## Core is shared by both apps and the tests
`Mac/Core` is compiled by the iPhone app, the Mac app and `swift test`. It imports Foundation only: never SwiftUI, UIKit or AppKit. `scripts/check_escape_hatches.py` fails on a UI framework import here.

## Put view decisions here as plain data
What a row says, which badges and labels it shows, a status's kind, a form's fields and the body a save sends, a filter's result, an errand's prompt: write these as `Sendable`, `Equatable` structs and pure functions (`BoardRow`, `BoardFilter`, `BoardAction`, `SettingsField`, `mergeWarnings`, `issuesNested`). Each app's view maps them to colours, fonts and symbols. This is how the two apps share behaviour without sharing views.

## Group by domain
Add to the domain file that owns the concept (`Board.swift` and `BoardLogic.swift`, `ConversationLogic.swift`, `FindingsLogic.swift`, `UsageLogic.swift`, `SettingsLogic.swift`, `AccountSettingsLogic.swift`, `Markdown.swift`, `Diff.swift`, `CarText.swift`), or start a new `<Domain>Logic.swift` for a new concept. A screen's view logic goes in its domain's `*Logic.swift`, tested by the matching `*LogicTests.swift`. Split a domain file by sub-concept once it passes about 700 lines rather than growing a grab bag.

## Every rule has a test
A function or type added or moved here gets a test in `MacTests/` in the same change.

## Tokens are generated
`BriareusTokens.swift` comes from briareus-contracts. Change tokens there and copy its `dist/swift/BriareusTokens.swift` over this one; never edit the file here.
