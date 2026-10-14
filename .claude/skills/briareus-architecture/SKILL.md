---
name: briareus-architecture
description: "Reference map of this repository, behind the always-loaded rules in CLAUDE.md: what each target compiles, where each feature lives in both apps, the catalog of shared components and Core view-logic, the known duplicates between the apps, and the recipe for splitting an oversized screen. Read it before locating existing code, adding a screen or component, or refactoring a large view."
---

# Briareus Architecture

Reference map of the codebase. `CLAUDE.md` holds the non-negotiable rules; this file holds the detail they refer to.

## Targets

| Target | Sources | Notes |
| --- | --- | --- |
| Briareus (iPhone, iPad, CarPlay) | `App/` + `Mac/Core/` | Cannot see `Mac/App/`. |
| Briareus Mac | `Mac/` | AppKit available; not sandboxed (SSH, SFTP). |
| BriareusMacCore (`swift test`) | `Mac/Core/` + `MacTests/` | Foundation only. |

Because the iPhone app cannot see `Mac/App/`, the only code both apps share is `Mac/Core`. Sharing behaviour between the apps means putting it in Core as data; sharing drawing between screens of one app means its shared layer (`Mac/App/Shared`, `Mac/App/Components.swift`; `App/Theme.swift` and, once created, `App/Shared/`).

## Layers

View (`App/**`, `Mac/App/**`) -> Model (`@MainActor ObservableObject`, `*Model.swift`, `Store`) -> Core (`Mac/Core`: `API.swift`, `JSON.swift`, `Cache.swift`, `*Logic.swift`).

## Features in each app

| Feature | iPhone (`App/`) | Mac (`Mac/App/`) | Core |
| --- | --- | --- | --- |
| Projects, conversations | `Conversations/` | `Sidebar/`, `Conversation/` | `ConversationLogic.swift`, `PhoneConversations.swift`, `SessionOverview.swift`, `LiveEvents.swift`, `EventStream.swift` |
| Board, pull requests, issues | `Board/` | `Board/` | `Board.swift`, `BoardLogic.swift`, `BoardEdits.swift`, `ProjectBoard.swift`, `IssuePage.swift`, `PullFiles.swift`, `Diff.swift` |
| Findings, Status, Usage | `Findings/` | `Findings/` | `FindingsLogic.swift`, `PhoneFindings.swift`, `UsageLogic.swift` |
| Settings | `Settings/` | `Settings/` | `SettingsLogic.swift`, `AccountSettingsLogic.swift` |
| Forge | `Forge/` | `Board/ProjectForgeTab.swift`, `Board/ForgeSiteView.swift` | `Forge.swift` |
| Shared browser | `Conversations/SharedBrowserScreen.swift` | `Conversation/SharedBrowserScreen.swift` | `SharedBrowser.swift` |
| Voice | `Voice/` | `Conversation/VoiceNote.swift` | `Voice.swift` |
| CarPlay | `Car/` | n/a | `CarText.swift` |
| SSH, SFTP, DB, terminal | n/a | `Remote/` | `SFTP*.swift`, `SQL.swift`, `VT.swift`, `TerminalInput.swift` |
| Files tab | n/a | `Board/ProjectFilesTab.swift`, `Board/FilesNavigator.swift` | `RepoFiles.swift`, `RepoIndex.swift`, `CodeSymbols.swift`, `CodeHighlight.swift` |
| Meeting, Mail | n/a | `Meeting/`, `Mail/` | `Meet*.swift`, `Mail.swift` |

## Component catalog

Search here before writing a component.

**Mac primitives** (`Mac/App/Components.swift`): `DashButtonStyle` with `ButtonKind` (prominent, bordered, plain, destructive), `IconButtonStyle`, `GlyphButton`, `StatusDot`, `Badge`, `Chip`, `Monogram`, `Notice`, `NoticeBox`, `LoadingNote`, `EmptyNote`, `SectionTitle`, `LabeledRow`, `Card`, `Segments`, `TabNav`/`TabNavItem`, `FieldStyle`, `FlowLayout`, `Clipboard`, `openWebURL`.

**Mac shared rows** (`Mac/App/Shared/Rows.swift`): `Badges` from `pullBadges(_:stack:) -> [BadgeSpec]`, `LabelChips`, `SessionRow`, `LinkedRow`, `MetaLine`/`MetaPart`, `PullRow`, `EpicProgress`, `IssueRowView`; glyph helpers `labelColor`, `severityColor`, `reviewGlyph`, `checkGlyph`, `toolGlyph`. Also `MarkdownView`/`RichText`/`CodeBlock`, `SelectableText`, `BrowserView`.

**Mac board kit** (`Mac/App/Board/BoardKit.swift`): `boardCall`, `ErrandLabel`, `BoardPopupMenu`, `ActionInputDialog`, `BoardRule`, `BoardBox`, `StatePill`, `BranchChip`, `WordFlow`, `CommentHead`, `CheckCounts`, `GlyphLabel`, `actionIcon`.

**Mac settings kit** (`Mac/App/Settings/SettingsKit.swift`): `SettingsPage`, `SettingsTabs`, `SettingsFieldBox`, `SettingsFieldLabel`, `SettingsTextArea`, `SettingsCheck`, `SettingsSelect`, `SettingsLabeledSelect`, `SettingsPair`, `SettingsStatusRow`, `SettingsHint`, `SettingsNote`, `SettingsHelpIcon`, `PopupMenu`.

**iPhone primitives** (`App/Theme.swift`): `StatusDot`, `StatusLabel`, `ErrorNotice`, `MarkdownText`, `CodeBlock`; otherwise system controls and `ContentUnavailableView`.

**iPhone board pieces** (`App/Board/BoardPieces.swift`): `BoardPullRow`, `BoardIssueRow`, `BoardSessionRow`, `BoardLinkedRow`, `BoardLabelChips`, `BoardBadge`, `ChecksBadge`, `BoardEpicProgress`, `BoardUpdated`, `ErrandNotice`, `BoardFlowLayout`, `boardErrands`, `errandSymbol`.

**iPhone settings kit** (`App/Settings/SettingsFormKit.swift`): `SettingsFormChrome`, `SettingsTextRow`, `SettingsValueRow`, `SettingsLabel`, `SettingsInfoButton`, `SettingsVerdict`, `SettingsErrorSection`, `SettingsUnavailableView`.

**Core view logic** (shared by both apps): `IssueRowContent` with `RowFact` and `SubIssueProgress`, `PullRowContent` with `PullMark`, `ChecksState` and `RowTone` (each app maps a tone with `Theme.color(_:)`; the reference for converging the rest), `BoardRow`, `BoardFilter`, `BoardAction`, `ReviewStatus`, `StackPosition`, `mergeWarnings`, `issuesNested`, `issuePrompt`, `SettingsField` and the settings form bodies, `CarText`.

## Known duplicates to converge

Done: the pull request row (`BoardPullRow` and `PullRow` both draw `PullRowContent`) and the issue row (`BoardIssueRow` and `IssueRowView` draw `IssueRowContent`, both epic bars draw `SubIssueProgress`).


These exist because the iPhone app cannot see `Mac/App/Shared`. Do not add to the list. When you touch one, move its decisions into Core (a function returning a struct or enum, tested in `MacTests`) and leave each app only the drawing.

| iPhone | Mac | Decision to move to Core |
| --- | --- | --- |
| `BoardSessionRow`, `BoardLinkedRow` | `SessionRow`, `LinkedRow` | Row text and status kind |
| `BoardLabelChips`, `boardLabelColor` | `LabelChips`, `labelColor` | Label colour parsing |
| `reviewStyle` | `reviewGlyph` | Review state to a symbol name (the colour already comes from `ReviewStatus.tone`) |
| `boardErrands`, `errandSymbol` | `rowActions`, `actionIcon` | Errand list and symbol name |
| `BoardFlowLayout` | `FlowLayout` | n/a (a pure `Layout`: candidate for a file both targets compile) |
| `App/Board/PullModel.swift` | `Mac/App/Board/PullModel.swift` | Merge gating, edit bodies and section availability |
| Each `*SettingsScreen.swift` pair | same names | Validation, dirty state and save bodies (`AccountSettingsLogic` is the model) |

## Oversized files

The ratchet blocks growth above 300 lines. The largest at the time of writing: `Mac/App/Board/ProjectFilesTab.swift` (1114), `Mac/App/Board/PullScreen.swift` (1013), `Mac/App/Conversation/SharedBrowserScreen.swift` (989), `Mac/App/Findings/FindingsScreen.swift` (891), `Mac/App/Conversation/ConversationScreen.swift` (811), `App/Board/IssueScreen.swift` (798), `App/Conversations/SharedBrowserScreen.swift` (780), `App/Board/PullScreen.swift` (778). Run `find App Mac/App -name '*.swift' | xargs wc -l | sort -n | tail -30` for the current list.

## Recipe: splitting an oversized screen

1. List the screen's sections (header, each tab, sidebar, toolbar, sheets) and the state each one reads.
2. Move non-drawing logic first: parsing, filtering, labels and request bodies to the domain's `Mac/Core/*Logic.swift` with tests; state and side effects to the screen's model.
3. Extract each section into a `View` struct taking only what it reads, in `<Screen>+<Section>.swift` beside the screen (or the feature kit if another screen uses it).
4. Replace any copied primitive with the catalog's component and literal styling with tokens.
5. Leave the screen file as the outline. Regenerate the project (`python3 scripts/generate-project.py`), build both schemes, run `swift test` and the ratchet.
6. Do the iPhone and Mac twins of the screen together when they share decisions, so the Core function lands once.
