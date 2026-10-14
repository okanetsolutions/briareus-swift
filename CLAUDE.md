# Claude Guide for Briareus (SwiftUI clients for iPhone, iPad, Mac and CarPlay)

This file holds the non-negotiable rules. The detail they refer to lives in two places:

- `.ai/rules/index.md` maps file globs to path-scoped rule files. Before planning or editing, find every row whose globs match the paths in scope, read those rule files, and run `grep -rin '<keyword>' .ai/rules` to catch what a path match misses. Do not write code until you are following every matching rule.
- The `briareus-architecture` skill is the reference map: what each target compiles, where each feature lives, and the catalog of shared components. Read it before locating existing code, adding a screen or writing a component.

## Targets and what each one compiles

| Target | Compiles | Can use |
| --- | --- | --- |
| Briareus (iPhone, iPad, CarPlay) | `App/` and `Mac/Core/` | Core and its own `App/` views. It cannot see `Mac/App/`. |
| Briareus Mac | `Mac/` (`Mac/App/` and `Mac/Core/`) | Core and its own `Mac/App/` views. |
| `swift test` (BriareusMacCore) | `Mac/Core/` and `MacTests/` | Core only. |

This is the most important fact about the repository's structure. A component in `Mac/App/Shared` is invisible to the iPhone app, so anything both apps need to decide (what a row says, which badges it shows, which errand is suggested, what a form sends) must live in `Mac/Core` as plain data and functions. Each app then only draws that data.

## Layers

All code follows strict layers and one-way dependencies:

- **View** (`App/**`, `Mac/App/**`): a SwiftUI `View` that lays out and draws. It reads a model or plain values and calls the model's methods on user actions.
- **Model** (`*Model.swift`, `App/Store.swift`, `App/ProjectFeed.swift`, the Mac's `*Model` classes): a `@MainActor final class ... : ObservableObject` that owns a screen's state, loads it through Core, and exposes intent methods (`merge()`, `save()`, `reload()`).
- **Core** (`Mac/Core/**`): the client API (`API.swift`), response types, the saved-response cache, and every pure rule (board rows and filters, settings forms, diffs, Markdown, what a car says). No SwiftUI, UIKit or AppKit.

View -> Model -> Core. Never the other way, and never skipping the model for anything with state or side effects.

Avoid these anti-patterns:

- `URLSession`, `URLRequest` or `API` calls from a `View` body or a view's `.task`/button closure that does more than call one model method.
- Parsing `JSON`, building request bodies, sorting, filtering or deciding labels and colours inside a view. Put the decision in Core as a function returning a value (see `pullBadges(_:stack:) -> [BadgeSpec]`) and let the view map it to colours.
- The same rule written twice, once in `App/` and once in `Mac/App/`. If both apps need it, it belongs in Core with one test.
- A model that draws (returns `some View`) or a Core type that knows about `Color` or `Font`.

## Views stay small and composed

- A screen file composes sections; each section is its own `View` struct with the narrowest input it needs (a value or a binding, not the whole model, unless it calls the model's intents).
- Extract a subview when a `body` or computed view property no longer fits on one screen (about 40 lines), when it is repeated, or when it has its own state.
- No view file over 300 lines. `scripts/check_escape_hatches.py` fails CI for a new file over 300 lines or an existing one that grows while above it. When you touch an oversized file, extract what you change instead of adding to it. Existing debt is tolerated; adding to it is not.
- One feature folder per area (`Board/`, `Conversation(s)/`, `Settings/`, `Findings/`, ...). A component used by one feature lives in that feature's kit file (`BoardKit.swift`, `SettingsKit.swift`, `App/Board/BoardPieces.swift`, `App/Settings/SettingsFormKit.swift`). A component used by two features moves to the app's shared layer (`Mac/App/Shared/`, and for the iPhone app `App/Shared/` once it exists).

## Reuse before writing

- Before writing a row, chip, badge, pill, box, notice, empty state or button style, check the component catalog in the `briareus-architecture` skill and search for it: `grep -rn "struct .*Chip\|struct .*Row\|struct .*Badge" App Mac/App`.
- Promote on second use. When you would copy a component, move it to the shared layer and use it from both places in the same change.
- Never copy a Mac component into `App/` under a new prefix (`BoardPullRow` beside `PullRow`, `BoardLabelChips` beside `LabelChips`). Move the decisions into Core and keep only the drawing per app.
- Reuse existing models, enums and Core types (`PullSummary`, `IssueSummary`, `BoardAction`, `ReviewStatus`, `SettingsField`) instead of introducing new variants.

## Styling comes from the tokens

- Colours from `Theme` (`Theme.ink`, `Theme.muted`, `Theme.accent`, `Theme.statusColor(_:)`), never `Color(hex:)`, `Color(red:...)` or `Color(.sRGB ...)` in a view.
- Corner radii from `BriareusRadius` (`.badge` for tags, `.md` for buttons, fields and rows, `.lg` for cards and menus, `.xxl` for code blocks and sheets, `.full` for pills).
- Mac text from `Theme`'s fonts (`Theme.body`, `Theme.footnote`, ...). The iPhone app keeps the system text styles (`.body`, `.footnote`) so Dynamic Type works. No `.font(.system(size:))` in either.
- The ratchet counts hard-coded radii, font sizes and colour literals across both apps and fails CI if the total rises. `Mac/Core/BriareusTokens.swift` is generated from briareus-contracts; change tokens there, never in this repository.

## Claude execution expectations

For every task, Claude must:

- Read the matching `.ai/rules` files and the architecture skill before editing.
- Keep views thin: layout and drawing only. Put screen state and side effects in the model and rules in Core.
- When a feature exists on both apps, change the Core rule once and both apps' drawing, and keep the two screens equivalent (README's promise that the apps match screen for screen).
- Prefer extracting and reusing to adding. Leave a touched oversized file smaller than you found it when the change allows.
- Match the surrounding comment style: a header comment saying what the file is for and doc comments on non-obvious properties.
- Regenerate the project with `python3 scripts/generate-project.py` after adding, moving or removing a source file, and commit the result.

## Testing expectations

- Every rule in Core has a test in `MacTests/`: board rows, filters, errands, settings bodies, parsing and what a car says. Moving logic out of a view into Core is the moment to add its test.
- Do not test layout. No assertions on view structure, padding or sibling order.
- Do not assert wording that is copy. Assert structure, values flowing through and state transitions.

## Definition of done

A change is done only when:

- The acceptance criteria are met on every app the feature exists on.
- `swift test` passes, and both schemes build (see README's Validation section).
- `python3 scripts/check_escape_hatches.py` exits zero against the PR's base.
- Logic added or moved is covered in `MacTests/`.
- No rule here or in `.ai/rules` is contradicted.

## Mandatory gate before pushing

Run `swift test`, both scheme builds and `python3 scripts/check_escape_hatches.py`, then follow the `code-review` skill before opening a PR. A skipped check is not a pass.

## Building, networking and agent skills

- After every change, build with the MobileBuildMCP server (formerly XcodeBuildMCP, registered in `.mcp.json`): the `Briareus` scheme for a simulator and the `Briareus Mac` scheme, and fix any errors before calling the change done. This adds to the mandatory gate above; it does not replace `swift test` or the escape-hatch check.
- The backend is a Laravel REST API using Sanctum token auth. Tokens live in the Keychain (`App/Keychain.swift` on the iPhone), never in `UserDefaults`.
- Networking uses async/await with `URLSession` and `Codable`, through `API` in `Mac/Core`, never from a view.
- Never hand-edit `Briareus.xcodeproj/project.pbxproj`. Add, move or remove source files and run `python3 scripts/generate-project.py`, as stated above.
- Use the project skills `swiftui-pro`, `swiftdata-pro` and `swift-concurrency-pro` when writing or reviewing Swift code. Where their advice conflicts with this file or `.ai/rules`, this repository wins. In particular, keep the deployment targets in `scripts/generate-project.py` (iOS 17, macOS 14) and use newer APIs only behind `#available`.
