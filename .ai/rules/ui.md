---
paths:
  - 'App/**'
  - 'Mac/App/**'
---

# Application UI consistency

These rules govern every screen of the Mac app and the iPhone and iPad app. Apply them to new screens and to the UI being changed. Existing inconsistencies are not permission to repeat a pattern or to redesign unrelated screens. Explicit product requirements take precedence; state an intentional exception and its reason in the PR.

## Shared foundation

- Build from the app's primitives before custom drawing. Mac: `Mac/App/Components.swift` (`DashButtonStyle`, `GlyphButton`, `Badge`, `Chip`, `Notice`, `NoticeBox`, `EmptyNote`, `SectionTitle`, `LabeledRow`, `Card`, `Segments`, `TabNav`, `FieldStyle`, `FlowLayout`) and `Mac/App/Shared/LoadingNote.swift` (`LoadingNote`). iPhone: system controls and `App/Theme.swift` (`StatusDot`, `StatusLabel`, `ErrorNotice`, `MarkdownText`, `CodeBlock`).
- Inherit the palette, text sizes, column widths and working indicator from the tokens (`Theme`, `BriareusRadius`, `BriareusLayout`). Do not choose a new colour, radius or card treatment per screen.
- Use the same SF Symbol for the same action and state across both apps. A state's symbol is named once in Core beside its tone (`ReviewStatus.symbol`, `ChecksState.symbol`, `PullMark.symbol`), using the Mac's set, which mirrors the Windows client; the errands' symbols are still named per app (`actionIcon(_:)`, `errandSymbol(_:)`). Symbols communicate an action or state; no decorative ones.
- The Mac uses the tokens' pixel sizes, as Windows does. The iPhone keeps system text styles so Dynamic Type keeps working.

## Screen patterns

| Screen | Pattern |
| --- | --- |
| List (projects, conversations, pull requests, issues) | One list, its filters and search above it, the row component the other app uses for the same item. |
| Record (pull request, issue, conversation) | Header with identity and state, then tabs or sections; each tab is its own view. Mac sidebars scroll on their own beside the content. |
| Settings form | Fields from Core's `SettingsField` definitions, the form's chrome (`SettingsFormChrome` on iPhone, `SettingsKit` on Mac), explicit Save, Discard asking first when dirty. |
| Dashboard (Status, Usage, Findings) | Summary counts first, then the lists or charts they summarise. |
| Workspace (shared browser, terminal, files) | Reuse the closest existing workspace; full-height layouts and special scrolling stay scoped to that screen. |

Both apps show the same screen for the same feature (README: "screen for screen"). When one changes, change the other or say in the PR why not.

## States and feedback

- Every screen that loads has distinct loading, empty, error and loaded states. Mac: `LoadingNote`, `EmptyNote`, `Notice`. iPhone: `ProgressView`, `ContentUnavailableView`, `ErrorNotice`.
- Distinguish an empty collection from no results for the current filters; the latter offers a way to clear them.
- While a write is pending, show progress and prevent a second submission. Report completion only once it is known.
- Confirm destructive and paid actions with the target and consequence visible. Ordinary saves, filters and navigation do not ask.
- Hide write controls a Read-only token cannot use, and controls for routes the server's catalog does not offer.

## Accessibility and verification

- Keep keyboard navigation and shortcuts on the Mac, VoiceOver labels on icon-only buttons, and Dynamic Type on the iPhone. Help text is supplementary; essential actions work without hover.
- Check light and dark mode, narrow and wide windows, long names, an iPad and the phone's single column for a changed screen.
- Do not claim visual verification from a build alone; say which screens you looked at.
