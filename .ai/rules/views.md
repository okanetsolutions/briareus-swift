---
paths:
  - 'App/**'
  - 'Mac/App/**'
---

# Views

## Views draw; they do not decide
A `View` lays out values and forwards user actions to one model method. Requests, JSON parsing, request bodies, sorting, filtering, validation and choosing a label, symbol or status belong in the model or in `Mac/Core`. A `.task`, `.onAppear` or button closure calls one model method; it does not hold a workflow.

## Keep files and bodies small
No view file over 300 lines; `scripts/check_escape_hatches.py` fails a new file over the limit or an oversized file that grows. Extract a subview when a `body` or computed view property passes about 40 lines, repeats, or owns state. Prefer a named `struct` over a `private var section: some View` once it takes inputs or has its own `@State`.

## Split a screen by section, not by accident
A screen file is the composition: header, sections, toolbar, sheets. Each section is a `View` in the same feature folder that takes the narrowest input it needs: values or bindings for drawing, the model only when it calls intents. When a screen passes 300 lines, move sections into `<Screen>+<Section>.swift` or a feature kit file and keep the screen file as the outline.

## Reuse before writing
Check the component catalog in the `briareus-architecture` skill before writing a row, chip, badge, pill, card, notice, empty state, segmented control or button style. A component used by one feature lives in its kit file; used by two features, it moves to the app's shared layer in the same change. Never copy a component between `Mac/App/` and `App/` under a new prefix: move the decisions it makes into `Mac/Core` and keep only the drawing per app.

## Style from tokens
Colours from `Theme`, radii from `BriareusRadius`, Mac fonts from `Theme`'s fonts, iPhone fonts from system text styles. No `Color(hex:)`, `Color(red:)`, `Color(.sRGB ...)`, `cornerRadius:` with a number or `.font(.system(size:))` in a view. The ratchet counts them and fails if the total rises.

## No networking in views
No `URLSession`, `URLRequest` or direct `API` use in a view. Requests go through `Mac/Core` and are called from a model. The ratchet fails a view file that starts using them.
