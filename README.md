# Briareus for iPhone, iPad, Mac and CarPlay

A native SwiftUI client for [Briareus](https://github.com/nadinyamaui/briareus), the server for running coding agents against your projects. It talks to the server's client API (`/api/v1`), as the Mac and Windows clients do, and works with any Briareus server you can reach over HTTPS. Requires iOS 17 or macOS 14 or later. Its one third-party dependency is Google's WebRTC ([stasel/WebRTC](https://github.com/stasel/WebRTC), a binary Swift package), which the iPhone app's voice mode talks to GPT-Realtime with.

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Build and run](#build-and-run)
- [Deploy](#deploy)
  - [1. Prepare the server](#1-prepare-the-server)
  - [2. Make the app yours](#2-make-the-app-yours)
  - [3. Install on your own device](#3-install-on-your-own-device)
  - [4. Distribute through TestFlight or the App Store](#4-distribute-through-testflight-or-the-app-store)
  - [5. Pair the app with the server](#5-pair-the-app-with-the-server)
  - [Releasing an update](#releasing-an-update)
  - [Troubleshooting](#troubleshooting)
- [Project layout](#project-layout)
- [Validation](#validation)
- [Boundaries](#boundaries)
- [Security and privacy](#security-and-privacy)

## What it does

The iPhone and iPad app opens on four tabs, the Mac app's sidebar strip laid out for a phone: **Projects** (the projects, their conversations and boards), **Findings** (the review rounds waiting across every project, with their count on the tab), **Usage** and **Settings**. It runs on the Mac app's core (`Mac/Core`), so both apps read the server the same way. The screen stays on while the app is open.

**Conversations**

- Lists the projects and conversations the device token permits, with search and status updates. A conversation with a pull request shows it in place of its dot, as Claude's list does: purple once merged, grey when closed, and while open, green, amber or red by its checks.
- Shows incremental transcripts with the time of each message, Markdown replies, agent questions and queued messages. The tools, commands and git steps an agent runs fold into one line between the messages, which opens to show them. A reply's table copies whole as Markdown with Copy table above it, and each cell selects and copies on its own.
- Starts conversations on any project from the Projects tab, or on the one open, on a chosen branch, provider, model and effort or on the project default, with the review loop and files attached.
- Sends follow-ups with photos and files attached, renames, stops, closes, reopens, compacts, clears and deletes sessions, one at a time or several selected at once.
- Shows a conversation's pull request, checks, reviews, findings and context use in a sheet, as the Mac's panel beside it does.
- Turns the review loop on or off from inside a conversation.
- Opens the session's shared browser, the headless Chromium its agent drives, full screen from the conversation's menu, or from the 🌐 line over the transcript while it is on: switch it on or off, watch the tab in view live and use it on the same tabs the agent does, with its tabs, an address field, back, forward and reload. A tap clicks, a drag scrolls the page (or, in Drag mode, drags in it), and the keyboard types into it, with Escape, Tab, the arrows and Paste above it.
- With an Admin token, opens a session's ⚡ Webhook from the conversation's menu (● while armed): arm it, set its hourly and turns-in-a-row caps, SSH unattended and the instructions webhook, copy its URLs and keys (hidden until shown), see held deliveries and pauses, and rotate its keys. Going back with changes not saved asks first.
- Triages a review round from its conversation or from the Findings tab: a verdict and a comment per finding, a note for the fix session, replies and deletions on a round that is not yours.
- Records voice notes and has the server transcribe them into the message box, in whichever language was spoken. On a server that cannot transcribe, the microphone says what the server is missing.
- On an iPad, keeps the projects and conversations in a column on the left and the chosen conversation on the right. A window too narrow for both falls back to the phone's single column.
- On a Mac, runs as a Mac app of its own (`Mac/`), the twin of [Briareus for Windows](https://github.com/okanetsolutions/briareus-windows): the same screens, layout and features, on the client API (`/api/v1`). See [The Mac app](#the-mac-app).

**Voice**

- Holds a spoken conversation about one project, opened from that project's screen (the waveform): what its conversations are doing, what an agent asks, which pull requests wait, which findings need a decision. It answers only when spoken to.
- Goes hands-free with one conversation, opened from that conversation's screen (the waveform): a line to its agent alone. What the user says for the agent is sent to it in their words, and the agent's replies and questions are read aloud as they come, with the phone locked too, so a question can be answered by voice. It reads the conversation, its pull request's changes and the review round it holds, completes that round, and stops a running turn; no tool names a conversation or a pull request, the phone puts the held ones in. The call stays up while the agent works.
- Talks with OpenAI's [GPT-Realtime mini](https://developers.openai.com/api/docs/models/gpt-realtime-2.1-mini), which picks the actions itself; the phone runs them on `/api/v1` with its own token.
- Everything it does stays on that project: no tool names a repository, and a conversation named by id is checked to be the project's first. It reads what a pull request changes (how many files, lines added and removed, its description, and each file's diff, to sum up what it touches), the project's open issues, any one of them in full with its description and latest comments, and starts an agent on one, as the board's own button does; starts a conversation, sends a message or answers an agent's question, stops a running turn, closes or deletes a conversation; starts a code review, implement feedback, fix checks or solve conflicts on a pull request; takes a yes or a no on each finding, on a pull request or in a review round a conversation holds; and merges a pull request, saying first what stands in its way (failing checks, conflicts, a missing code-approved label, a place in a stack above position 1) and merging the head it read. Everything is done as soon as it is asked for; only a merge is read back and runs on a yes said after it.
- Talks to OpenAI directly from the phone with an API key kept in its Keychain (Settings › Voice), over WebRTC: the microphone and the voice travel on audio tracks, with WebRTC's echo cancellation and jitter buffer, and events on a data channel.
- Goes on with the phone locked, and ends on its own after a silence (3 minutes by default), as GPT-Realtime bills the audio it hears and says.
- Shows what the conversation has cost under its controls, ticking while it runs: each response's and each transcription's tokens, as OpenAI reports them, at gpt-realtime-2.1-mini's and gpt-4o-mini-transcribe's published prices. Each finished conversation's time and cost is kept on the phone, and Settings › Voice adds them up: time, cost and cost per minute. An estimate; OpenAI's bill is the reference.

**Project board**

- Shows open pull requests: labels, whether they conflict with their base, the state of their checks, “assignee @a | author @b | reviewers @c”, linked issues with their project Status (not their open or closed state), and stack position, narrowed by author, reviewer or label.
- Opens a pull request on its description, file changes with diffs, reviews, the issues it closes (this repository's open on the app's issue screen), the project boards those issues are on with their Status and fields, findings, the conversations already run on it and its ▶ Run preview in an embedded browser.
- Records fix, optional or dismiss decisions on findings, and merges when the server offers it, saying first what stands in the way. A pull request on the board's list merges from its row too (swipe it left, or hold it): the row's conflicts and checks are named first, and the head the pull request is read at is the one merged.
- Serves a project's default branch from its screen (Run default branch), as a pull request's ▶ Run does: in a fresh workspace with the project's run commands, its setup's log until the page is up, then the page in an embedded browser, with the run profile, Reload, Safari and Delete this run in its menu.
- Starts the board's errands on a pull request: run, code review, solve conflicts, fix failing checks, implement feedback, feedback in your own words, test sheet, record QA, PR body and delete my comments. The one the pull request's state asks for is marked as suggested, named on its row in the list and offered as a button above Squash and merge.
- Lists the repository's open issues, sub-issues nested under their epic, with the pull requests answering each, narrowed by author, assignee (No assignee among them) or label, starts a session on an issue and closes one as completed or not planned.
- Opens an issue as the Mac does: its state and who opened it, the body, every sub-issue of an epic, the sessions started on it, its assignees, labels, type, project fields, milestone, parent and, under Development, the pull requests linked to close it, then its timeline, a page at a time with Show more activity. A session starts on it at a tap: the page already says it is paid and whether one is at work.
- Edits an issue or a pull request on GitHub: its title and Markdown description, its labels as a comma-separated list, and its assignees, Assign me included (the GitHub login you give the first time is kept on the phone). A pull request's Update branch merges its base into it at the head that was read, once you confirm.
- The GitHub Projects board stays on the Mac app.
- With an Admin token, lists the Laravel Forge servers the project may use from the project screen's menu, each with its sites, the project's own first. A site opens on its overview, its deploy script and its `.env`, which is read only on Show .env; both are edited and saved to Forge, and replacing the `.env` asks first.

**Usage and Settings**

- Shows what the projects spent over a window, by project, activity, provider and model, with the costliest sessions; an admin token sees every project's, others this month's for their own.
- With an admin token, edits the server's settings as the Mac app does: projects (active or not, their GitHub Projects board and autonomous review loop) and their order, providers and their logins, the database pool, SSH servers with the database login each stores, Forge accounts, and Slack workspaces with the channels each project may post to. Each field's hint is behind an ⓘ beside it.

**In the car**

- Runs in CarPlay as a voice-based conversational app, on iOS 26.4 or later. A car has no keyboard, so what the agent is told is dictated; what was understood is shown and sent on a yes. The app listens and never speaks.
- Chooses a project, a conversation, a pull request or an issue from lists, and keeps the one chosen in hand on the voice screen.
- Starts a conversation from a dictated task, on a chosen branch, model and effort or on the project default. Sends follow-ups, answers an agent's question with one of the answers it offers, renames by dictation, stops, closes, reopens and deletes, removes queued messages and turns the review loop on or off.
- Completes a review round's triage, with a verdict per finding and a dictated note for the fix session.
- Shows a pull request's state, checks and reviews, records decisions on its findings, merges it, and starts the board's errands on it, feedback in your own words included. Starts a session on an issue, and closes one.
- Asks before every paid or destructive action. Revokes the token or forgets the connection; pairing takes the phone.

**Connection**

- Pairs with a per-device token stored in Keychain, and revokes it remotely or forgets the local connection.
- Hides write controls on a Read-only token. The route catalog the server publishes (`/api/v1/openapi.json`) keeps what it does not offer unavailable, so the app adapts to older and newer servers.
- Saves projects, conversations, transcripts and pull requests on the device. A screen opens on what it last showed and then asks the server only for what changed; a saved transcript resumes from its last event, and pulling down reads it again in full.
- Pauses polling in the background and covers the app switcher snapshot.

## The Mac app

The Mac app is built from `Mac/` by the **Briareus Mac** scheme and does what [Briareus for Windows](https://github.com/okanetsolutions/briareus-windows) does, screen for screen: the sidebar with the ＋ New session strip (WhatsApp, Slack, 📊 Usage, ⚑ Findings) and ⚙ Settings at its foot, and the player for what Spotify or Music is playing; conversations with Markdown replies, tool clusters, attachments and voice notes, beside the pull request panel; the project board with pull requests, issues, errands, the pull request page and its Run tab in an embedded browser; the Findings queue; the 📊 Usage screen; ⚙ Settings for projects, providers, the database pool, SSH servers (with the database login each stores, on a Database tab); and SSH and SFTP sessions on a project's servers, run by this Mac's own `ssh` and `sftp`, so `~/.ssh` applies. A project that names a GitHub Projects board (in ⚙ Settings → Projects, by pasting its address) gets a ▦ Board tab after Issues, as GitHub's board view draws it: the view's columns side by side, each scrolling on its own above a sideways bar, with their counts and Story Points totals, only the project's own cards, an assignee picker that narrows cards, counts and totals, and on each issue card the pull requests closing it; a card opens its issue or pull request, and one dragged to another column moves there at once and on GitHub (`POST /project-board/move`), put back with the reason when GitHub refuses. The issues a pull request closes carry their GitHub project fields: on the board each linked issue line ends with its project Status as a chip, read in the background one issue at a time, and the pull request's sidebar lists their boards under Projects, with Status, priority, iteration and the rest. The Mac app is built from `Mac/` by the **Briareus Mac** scheme and does what [Briareus for Windows](https://github.com/okanetsolutions/briareus-windows) does, screen for screen: the sidebar with the ＋ New session strip (WhatsApp, Slack, 📊 Usage, ⚑ Findings) and ⚙ Settings at its foot, and the player for what Spotify or Music is playing, with the Mac's output volume under it (the speaker mutes, the slider sets it, the wheel over the player steps it); conversations with Markdown replies, tool clusters, attachments and voice notes, beside the pull request panel; the project board with pull requests, issues, errands, the pull request page and its Run tab in an embedded browser; the Findings queue; the 📊 Usage screen; ⚙ Settings for projects (each switched active or not from its form, with its autonomous review loop on the Code review tab, and moved up and down the list with the ↑ and ↓ on its row), providers, the database pool, SSH servers (with the database login each stores, on a Database tab), Laravel Forge accounts (an organization, its write-only token and the projects it serves) and Slack workspaces (who they send as, the Request URL to copy for Slack's Event Subscriptions, and each project's channels, direct messages and approval); and SSH and SFTP sessions on a project's servers, run by this Mac's own `ssh` and `sftp`, so `~/.ssh` applies. The Mac app is built from `Mac/` by the **Briareus Mac** scheme and does what [Briareus for Windows](https://github.com/okanetsolutions/briareus-windows) does, screen for screen: the sidebar with the ＋ New session strip (WhatsApp, Slack, 📊 Usage, ⚑ Findings) and ⚙ Settings at its foot, and the player for what Spotify or Music is playing; conversations with Markdown replies, tool clusters, attachments and voice notes, beside the pull request panel; the project board with pull requests, issues, errands, the pull request page and its Run tab in an embedded browser; the Findings queue; the 📊 Usage screen; ⚙ Settings for projects, providers, the database pool, SSH servers (with the database login each stores, on a Database tab); and SSH and SFTP sessions on a project's servers, run by this Mac's own `ssh` and `sftp`, so `~/.ssh` applies; and beside those on the board, a ▶ Run tab that serves the project's default branch with a run profile, a ⛁ Database tab that browses a server's MySQL databases, tables and rows through that same `ssh`, and a ☁ Forge tab with the Laravel Forge servers and sites the project may use, each site's deploy script and `.env` editable. A 🗂 Files tab browses the project's repository as PhpStorm's project view does: the tree at a branch (the default one, or any from its ▾) down the left, Go to File (⇧⌘O) over it, and the files opened from it as tabs on the right, read-only with line numbers, their language's colours and the find bar (⌘F); a binary file or one over 1 MB opens on GitHub instead. The server reads GitHub for it (`GET /repo/tree`, `GET /repo/file`), pinned to the commit the branch was at, so the tab shows only on a server that has those routes. A pull request's errands include 📋 Test sheet and 🎬 Record QA, which runs the sheet in a fresh workspace and records a video of each scenario. The Issues tab is narrowed by assignee too, No assignee among them. A pull request’s row reads its facts split by pipes, with “assignee @a”, “author @b” and its reviewers, and no branch or closing issue state; its ↳ Merge button confirms, reads the pull request and squash-merges it at the head that read returns. A pull request’s closing issue, under Development, opens in the app. On the pull request page’s tabs with the sidebar, the title and tabs stay at the top while the tab scrolls, and the sidebar stays in view beside it, scrolling on its own. An issue opens as GitHub lays it out: its state and who opened it, the body, every sub-issue, the conversations started on it and its timeline a page at a time (`GET /issues/{n}`, `GET /issues/{n}/timeline`), beside a sidebar with its actions, assignees, labels, type, Projects fields, milestone, parent and, under Development, its linked pull requests. An open pull request or issue is edited on GitHub from the app: Edit beside its title changes the title and the Markdown description, Edit labels… sets its labels as a comma-separated list, and Edit assignees ▾ assigns or unassigns you (the GitHub login you give the first time, kept in the app’s defaults) or sets the list; a pull request’s Update branch merges its base into it at the head that was read, once you confirm (`PATCH /pulls/{n}`, `PATCH /issues/{n}`, `POST /pulls/{n}/update-branch`). The Mac app is built from `Mac/` by the **Briareus Mac** scheme and does what [Briareus for Windows](https://github.com/okanetsolutions/briareus-windows) does, screen for screen: the sidebar with the ＋ New session strip (WhatsApp, Slack, 📊 Usage, ⚑ Findings) and ⚙ Settings at its foot, and the player for what Spotify or Music is playing; conversations with Markdown replies, tool clusters, attachments and voice notes, beside the pull request panel; the project board with pull requests, issues, errands, the pull request page and its Run tab in an embedded browser; the Findings queue; the 📊 Usage screen; ⚙ Settings for projects, providers, the database pool, SSH servers (with the database login each stores, on a Database tab); and SSH and SFTP sessions on a project's servers, run by this Mac's own `ssh` and `sftp`, so `~/.ssh` applies. 🎙 Meet in a project's header joins your meeting for you: an ElevenLabs agent hears the meeting app you pick (Teams, Zoom, Meet in a browser, or every app) through ScreenCaptureKit, which asks for Screen & System Audio Recording, speaks in your own ElevenLabs voice into a virtual microphone such as BlackHole 2ch, never opens your microphone, and looks the project up with the Windows client's read-only tools; the project's 🎙 Meeting tab shows the transcript as a chat, and ⚙ Settings → Meeting assistant keeps the ElevenLabs API key (in the keychain), the voice ID, your name and wake words, the device it speaks into, and every meeting's time and cost. The Mac app is built from `Mac/` by the **Briareus Mac** scheme and does what [Briareus for Windows](https://github.com/okanetsolutions/briareus-windows) does, screen for screen: the sidebar with the ＋ New session strip (WhatsApp, Slack, 📊 Usage, ⚑ Findings) and ⚙ Settings at its foot, and the player for what Spotify or Music is playing; conversations with Markdown replies, tool clusters, attachments and voice notes, beside the pull request panel; the project board with pull requests, issues, errands, the pull request page and its Run tab in an embedded browser; the Findings queue; the 📊 Usage screen; ⚙ Settings for projects, providers, the database pool, SSH servers (with the database login each stores, on a Database tab); and SSH and SFTP sessions on a project's servers, run by this Mac's own `ssh` and `sftp`, so `~/.ssh` applies. 🌐 Browser in a conversation's header (● while it runs) docks the session's shared browser, the headless Chromium its agent drives, as a column beside the conversation in the panel's place: switch it on or off, watch the tab in view live (`GET /sessions/{id}/browser/stream`) and click, drag, scroll, type and paste into it (⌘ acts as the page's Ctrl) on the same tabs the agent uses, with its tabs, an address field (⌘L), back, forward and reload above it; drag its divider to resize it, expand it over the conversation, or pop it out into a window of its own that docks back. A reply's table copies whole as Markdown with Copy table above its right edge, and its cells select and copy with the rest of the text, tab-separated, a line per row. An Admin token gets ⚡ Webhook in a conversation's header (● while armed): arm the session's webhook, set its hourly and turns-in-a-row caps, SSH unattended and the instructions webhook, copy its URLs and keys (hidden until shown), see held deliveries and pauses, and rotate its keys. It talks to the client API (`/api/v1`) with a device token, as the Windows client does, and is not sandboxed, since the SSH and SFTP sessions read `~/.ssh`. It keeps itself up to date from this repository's releases: it checks GitHub shortly after launch and every six hours, and when a newer release is out, downloads its `Briareus-mac.zip` (redirects followed only to GitHub's own hosts), checks it against the size and SHA-256 GitHub records for it, unpacks it and moves the new `Briareus.app` in place of the running one (kept beside it as `Briareus.app.old` until the next start); the version at the foot of the sidebar then turns into the new one, in the accent colour, and opens a menu to restart into it, check now, read the release notes or turn off “Install updates automatically” (off by default in a Debug build, so a release does not replace it). Its core (`Mac/Core`), which the iPhone and iPad app compiles too, is tested with `swift test`.

## Requirements

| To | You need |
| --- | --- |
| Build and run in the simulator | A Mac with Xcode 16 or later |
| Run the Mac app | macOS 14 or later, and an Apple developer account signed in to Xcode |
| Install on your own device | A free or paid Apple developer account signed in to Xcode |
| Distribute through TestFlight or the App Store | [Apple Developer Program](https://developer.apple.com/programs/) membership |
| Use the app in a car | iOS 26.4 or later, and a build made with Xcode 26.4 or later and signed with the CarPlay entitlement Apple granted to your team |
| Use the app | A Briareus server with the client API (`/api/v1`), reachable over HTTPS, and a token |
| Run the core tests only | Swift 5.9 or later, on macOS or Linux |

## Build and run

1. Clone this repository.
2. Open `Briareus.xcodeproj` and select the **Briareus** scheme.
3. Select an iPhone or iPad simulator and Run. The simulator needs no signing team.
4. For the Mac app, select the **Briareus Mac** scheme and **My Mac**, and Run. It keeps its token in the keychain under the team's access group, so it needs a signing team.

The checked-in project works without installing a generator. After adding or removing source files, regenerate it and commit the result:

```sh
python3 scripts/generate-project.py
```

The generator rewrites the project's build settings, so lasting changes to the bundle identifier, team or version belong in [scripts/generate-project.py](scripts/generate-project.py), not in Xcode's settings pane. CI fails when the checked-in project differs from what the generator produces.

## Deploy

A deployment has two halves: a Briareus server exposing the client API, and a signed build of this app on the device. Signing identities and provisioning profiles are intentionally not in this repository.

### 1. Prepare the server

1. Deploy a recent version of [Briareus](https://github.com/nadinyamaui/briareus) and publish it on an HTTPS hostname. Plain HTTP is refused by the app.
2. Issue the first token on the server with `npm run create-token -- --label Phone` (restart once if that run wrote `AUTH_SECRET`). The client API fails closed until then.
3. For voice notes, set `OPENAI_TRANSCRIBE_API_KEY` and `OPENAI_TRANSCRIBE_MODEL` on the server. Without them everything else works and the microphone explains what is missing.
4. If an access proxy such as Cloudflare Access protects the server, exempt only `/api/v1` and `/api/v1/*` from its interactive login. The token still guards every request. Do not exempt the whole hostname. The server's [client API guide](https://github.com/nadinyamaui/briareus/blob/main/docs/api-v1.md) has the exact steps.
5. Check the endpoint from outside your network, without cookies:

   ```sh
   curl -i https://briareus.example.com/api/v1/
   ```

   A `401` with `application/json` means the endpoint is reachable and waiting for a token. A redirect or an HTML page means a proxy still intercepts the path.

The app never changes server or proxy settings.

### 2. Make the app yours

The project ships with its maintainers' bundle identifier and signing team. To sign it with your own account, edit these values in [scripts/generate-project.py](scripts/generate-project.py):

| Setting | Where | Set it to |
| --- | --- | --- |
| `PRODUCT_BUNDLE_IDENTIFIER` | app and UI test targets | An identifier you own, such as `com.example.briareus` and `com.example.briareus.uitests` |
| `DEVELOPMENT_TEAM` | app and UI test targets | Your ten-character Apple team ID |
| `MARKETING_VERSION` | app target | The version users see, such as `1.0` |
| `CURRENT_PROJECT_VERSION` | app target | The build number; raise it for every upload |

Then regenerate the project:

```sh
python3 scripts/generate-project.py
```

Your team ID is under **Membership details** in the [Apple developer account](https://developer.apple.com/account). For a one-off build you can instead override the values on the `xcodebuild` command line, as the examples below do, and leave the repository untouched.

### 3. Install on your own device

1. Connect the iPhone or iPad, unlock it and trust the Mac. Turn on **Settings → Privacy & Security → Developer Mode** on the device.
2. In Xcode, check that your team appears under **Signing & Capabilities** with automatic signing on.
3. Select the device as the destination and Run.

With a free Apple account the build expires after seven days and must be reinstalled; a paid membership lasts a year.

### 4. Distribute through TestFlight or the App Store

One-time setup:

1. Register the bundle identifier under **Certificates, Identifiers & Profiles** in the developer account, or let Xcode's automatic signing do it.
2. Create the app in [App Store Connect](https://appstoreconnect.apple.com) with the same bundle identifier.

From Xcode:

1. Select **Any iOS Device (arm64)** as the destination.
2. **Product → Archive**.
3. In the Organizer, **Distribute App → App Store Connect → Upload**.

From the command line, archive first:

```sh
xcodebuild -project Briareus.xcodeproj -scheme Briareus -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Briareus.xcarchive \
  DEVELOPMENT_TEAM=YOURTEAMID PRODUCT_BUNDLE_IDENTIFIER=com.example.briareus \
  CURRENT_PROJECT_VERSION=2 -allowProvisioningUpdates archive
```

Save this as `ExportOptions.plist`, outside the repository or left uncommitted:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>teamID</key><string>YOURTEAMID</string>
    <key>signingStyle</key><string>automatic</string>
</dict></plist>
```

Then export and upload:

```sh
xcodebuild -exportArchive -archivePath build/Briareus.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export \
  -allowProvisioningUpdates
```

Set `destination` to `export` to get an `.ipa` in `build/export` instead of uploading. On a machine without a signed-in Xcode, such as a CI runner, add `-authenticationKeyPath`, `-authenticationKeyID` and `-authenticationKeyIssuerID` with an [App Store Connect API key](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api), kept in the runner's secrets.

Once the build finishes processing in App Store Connect:

- **TestFlight, internal**: add members of your team under **TestFlight → Internal Testing**. They get the build at once.
- **TestFlight, external**: create a group and submit the build for beta review. Reviewers need a server address and a device token to get past pairing; put them in the test information.
- **App Store**: fill in the listing and the privacy answers, then submit for review with the same demo access.

The app declares that it uses no non-exempt encryption (`ITSAppUsesNonExemptEncryption` is false), so uploads are not held for export compliance. It asks for the microphone only when a voice note is recorded.

### 5. Pair the app with the server

1. Issue a token: the first with `npm run create-token` on the server, later ones the same way. Give the device a name, choose the projects it may see, **Read**, **Manage** or **Admin**, and an expiry.
2. In the app, enter the public HTTPS server address (or its `/api/v1` URL) and the one-time token.

Issue one token per device. **Manage** permits paid agent starts, messages, GitHub changes and session deletion on the chosen projects; **Read** permits none of them; **Admin** reaches every project and the server's settings.

A revoked or expired token returns the app to pairing; issue a replacement. Forgetting the connection removes local credentials and saved conversations only. It does not revoke the server token or stop running agents.

### CarPlay

CarPlay lists an app only when it is signed with a CarPlay entitlement, and Apple grants those to a team on request. Briareus asks for the one for voice-based conversational apps, `com.apple.developer.carplay-voice-based-conversation`.

1. Request the entitlement for your team at [developer.apple.com/contact/carplay](https://developer.apple.com/contact/carplay/), in the voice-based conversational category.
2. Once granted, add the CarPlay capability to the app's identifier under **Certificates, Identifiers & Profiles**.
3. Set `CARPLAY_ON_DEVICE = True` in [scripts/generate-project.py](scripts/generate-project.py) and regenerate the project. Builds for a device are then signed with [App/Briareus-CarPlay.entitlements](App/Briareus-CarPlay.entitlements).

Until then the flag stays off: a build that asks for an entitlement its team does not have fails to sign. Builds for the simulator always carry it, since the simulator asks for no grant.

Pair on the phone first. With transcription off on the server the car still works through its lists, but nothing can be dictated.

### Releasing an update

1. Raise `CURRENT_PROJECT_VERSION`, and `MARKETING_VERSION` for a user-visible release, in the generator.
2. Regenerate the project and commit it.
3. Run the [validation](#validation) commands.
4. Archive and upload as above.

App Store Connect rejects an upload whose build number it has already seen for that version.

### Troubleshooting

| Symptom | Cause |
| --- | --- |
| The app shows a redirect or an HTML page while pairing | An access proxy still intercepts `/api/v1`, or the address points at the wrong host |
| The address is rejected | It is not HTTPS |
| Pairing reappears during use | The token was revoked or expired, or the server's `AUTH_SECRET` was rotated |
| A project is missing | The token does not include it |
| Write controls are missing | The token is Read only, or the server does not offer that operation |
| Briareus is missing from the CarPlay home screen | The build is not signed with the CarPlay entitlement, or the phone runs an iOS before 26.4 |
| The car says to connect on the iPhone | The phone is not paired, or was restarted and not unlocked since |
| The microphone explains that transcription is off | The server lacks the transcription settings from step 1 |
| Signing fails with "no profiles found" | The bundle identifier belongs to another team; choose your own in step 2 |
| Xcode changes disappear after regenerating | They were made in Xcode instead of in the generator |

## Project layout

| Path | Contents |
| --- | --- |
| `App/` | The iPhone and iPad app: the store, navigation and theme at the top, and the screens by tab in `Conversations/`, `Board/`, `Findings/` (and Usage), `Settings/` and `Car/` (the CarPlay scene) |
| `Mac/` | The Mac app (`Mac/App`) and the core both apps compile (`Mac/Core`): the client API, models, saved-response cache, board, diff, Markdown and settings logic, and what a car's screen says. No UIKit, AppKit or SwiftUI in the core |
| `MacTests/` | Core tests, run with `swift test` |
| `UITests/` | The pairing UI test, run in the simulator |
| `scripts/generate-project.py` | Generates `Briareus.xcodeproj` |
| `.github/workflows/ios.yml` | Continuous integration |

## Validation

```sh
swift test
```

```sh
xcodebuild -project Briareus.xcodeproj -scheme Briareus \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Briareus.xcodeproj -scheme "Briareus Mac" \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

```sh
xcodebuild -project Briareus.xcodeproj -scheme Briareus \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO test
```

Choose an installed simulator for the last command (`xcrun simctl list devices available`).

The GitHub Actions workflow runs on every pull request and on pushes to `main`, as parallel jobs:

| Job | What it checks |
| --- | --- |
| Core tests | The checked-in project matches the generator, then `swift test` |
| Simulator build | Builds for the simulator and uploads a simulator `.app` zip |
| iPhone build | Builds the Release configuration for a physical device, unsigned |
| Mac build | Builds the Mac app, unsigned |
| Pairing UI test | Boots a simulator, runs the UI test and uploads the results |
| ios | Passes only when every job above passed; the one check to require in branch protection |

The simulator artifact is not an installable IPA, and the workflow neither signs nor uploads to App Store Connect.

A second workflow, **Release**, runs on every push to `main`, so each merged pull request becomes a [release](https://github.com/okanetsolutions/briareus-swift/releases), as Briareus for Windows does. It tags the merged commit with the next minor version (`v1.1.0`, `v1.2.0`, …) and builds with that version and the commit count as the build number, without committing them back. The release attaches `Briareus-mac.zip` and `Briareus-iphone-simulator.zip`. The Mac app is signed ad hoc: macOS asks to confirm the first launch (right-click → Open), and without the team's keychain access group the app keeps its token in the login keychain. Pushing a `v*` tag by hand releases that tag as it is.

Tests exercise the saved-response cache, origin validation, credential headers, operation bodies, redirect rejection, non-JSON responses, expiry, rate limiting, write timeouts without retry, revocation, response compatibility, transcript cursor and deduplication, runtime selection, pull request file paging, diff line numbering, board rows, filters, errands, issue nesting, and conversations and pull requests as a car's screen words them. The simulator test verifies pairing and HTTP rejection without a live server or a real token.

Manual acceptance with a deployed test project:

- Pair with a Read-only token; verify only its projects appear and mutation controls are absent.
- Pair with Manage, start a conversation, send a follow-up and check the Mac app sees it once.
- Open a conversation whose agent ran tools, commands and git steps; verify the transcript shows only the messages, questions and turn endings.
- Background/foreground and leave/reopen the conversation; verify it opens at once on the saved transcript, then shows incremental updates and no duplicate events.
- Quit and relaunch the app; verify projects appear before the server answers and refresh afterwards.
- Test a question, queued follow-up, stop, rename, close and reopen; confirm before deleting a disposable session.
- Open the pull requests and compare labels, conflicts, checks and filters against the Mac app's board; open a pull request and compare checks, reviews and findings. The actions start paid agents and may write to GitHub.
- Triage a round of findings from the project's Findings button and toggle the review loop from a conversation; verify the Mac app shows the same state.
- Revoke the token on the server (`npm run create-token -- --revoke`) during polling and verify pairing appears; also test self-revocation and local-only forgetting.
- Record a voice note in a conversation and in a new one; verify its text lands at the end of the box, that discarding sends nothing, that a Read-only token shows no microphone, and that a server without transcription explains what it is missing when the microphone is pressed.
- Lose networking during a write; refresh and check the outcome before submitting it again.
- Test Dynamic Type, VoiceOver, landscape, dark mode, an iPad and a physical iPhone.
- In CarPlay, with the phone locked: choose a project and a conversation, dictate a message, answer no and yes when it is shown, and check the Mac app sees it once. Start a conversation, stop the agent, triage a round of findings, look at a pull request's checks, start an errand on it, check that music comes back after each dictation and that the app never speaks. Check that every list opens from the voice screen and that none goes deeper than two screens.
- On a Mac, choose a project and a conversation, resize the window, and check the conversation goes on updating with another app in front.

## Boundaries

The iPhone and iPad app has what the Mac app has, except what needs the Mac itself: SSH and SFTP sessions (run by the Mac's own `ssh` and `sftp`), the music player and the WhatsApp and Slack web apps. The API offers no push notifications.

- In a car the agent's replies are not shown or read aloud: the screen says what a conversation is doing and what it asks, and the transcript, file changes and diffs stay on the phone. Search, and a branch that is not on the list, need the phone too, as does pairing.
- CarPlay lists show as many rows as the car allows, fewer while it moves; the rest are on the phone.
- Diffs GitHub does not return (binary or very large files) open on GitHub instead.
- Review and the board's other errands always use the runtime configured on the server.
- A pull request's labels and conflicts come from the board, which lists open pull requests only, so a merged or closed one shows neither.
- Starting an epic, which picks an orchestrator's and its workers' models, is not offered by the apps.

## Security and privacy

- HTTPS is required. The transport has no cookies or HTTP cache, [refuses all redirects](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:)), and never automatically retries a write.
- No shared secret is built into the app. Each device holds its own token, in Keychain, scoped by canonical server origin and never leaving the device. On a Mac it is readable [while unlocked](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly); on an iPhone or iPad [from the first unlock after a restart](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly), since in a car the app runs with the phone locked.
- Only the server origin is saved in UserDefaults; the privacy manifest declares that use.
- Saved responses live in the app's Caches directory, [protected until the first unlock after a restart](https://developer.apple.com/documentation/foundation/fileprotectiontype/completeuntilfirstuserauthentication) for the same reason, and are left out of backups. They are erased when the connection is forgotten, revoked, expired or replaced by another device token, and entries untouched for 30 days are dropped.
- Voice notes, and what is dictated in a car, are sent to your server for transcription and nowhere else by the app.
- No analytics or third-party tracking SDK is included. Your server processes conversations under its own policies.
