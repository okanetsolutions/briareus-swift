---
paths:
  - '**/*Model.swift'
  - 'App/Store.swift'
  - 'App/ProjectFeed.swift'
  - 'App/LiveFeed.swift'
  - 'Mac/App/Store.swift'
  - 'Mac/App/Shared/ProjectsModel.swift'
---

# Models

## One model per screen, owning its state and side effects
A screen with loading, writes or polling gets a `@MainActor final class <Screen>Model: ObservableObject`. It holds the `@Published` state the view draws, loads through `Mac/Core` (or the app's `Store`/`boardCall`), and exposes intent methods named after what the user does (`merge()`, `save()`, `reload()`, `delete(_:)`). Views own it with `@StateObject` and pass it down only to subviews that call its intents.

## Models orchestrate; Core decides
A model sequences calls and updates state. The rules it applies (what a request body contains, whether a form is valid or dirty, which rows a filter keeps, which errand is suggested, what a merge warns about) are Core functions or types, so both apps share them and `MacTests` covers them. When a rule appears in both an `App/` model and a `Mac/App/` model, move it to Core in that change.

## Models never draw
A model returns values, not `some View`, `Color` or `Font`. Map Core values to colours and symbols in the view or in a small view-side helper.

## Split a model that does two jobs
A model over about 300 lines that serves several tabs or panels is split by tab: a child model per independently loaded part (as `PullFilesModel` is for a pull request's files), held by the parent.
