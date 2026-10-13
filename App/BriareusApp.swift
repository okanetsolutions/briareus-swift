import SwiftUI

@main
struct BriareusApp: App {
    @StateObject private var store = Store.shared
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup { shell { RootTabs() } }
        // A conversation, Findings, Usage or a shared browser in a window of its own (on an iPad), on the same store.
        WindowGroup(id: DetachedPage.scene, for: DetachedPage.self) { $page in
            shell {
                if let page { DetachedPageView(page: page).environment(\.inOwnWindow, true) } else { RootTabs() }
            }
        }
    }

    /// What every window holds around its page: pairing until connected, the cover while the app is out of sight, and
    /// the store's restoring and polling, which follow the app as a whole (this is the app's phase) rather than a window.
    private func shell<Page: View>(@ViewBuilder _ page: () -> Page) -> some View {
        ZStack {
            Group {
                if store.client != nil { page() } else { PairingView() }
            }
            if phase != .active {
                Theme.canvas.ignoresSafeArea()
                Label("Briareus", systemImage: "square.stack.3d.up.fill").font(.largeTitle.bold()).foregroundStyle(Theme.accent)
            }
        }
        .tint(Theme.accent)
        .noWritingTools()
        .environmentObject(store)
        .task { await store.restore() }
        // Polling stops while the app is out of sight; the car's screen keeps it going on its own.
        .onChange(of: phase, initial: true) { _, now in
            store.active = now == .active || CarScreen.connected
            // The screen stays on while the app is open, as an agent's work is watched rather than touched; iOS
            // locks it again on its own schedule once the app leaves the front.
            UIApplication.shared.isIdleTimerDisabled = now == .active
        }
    }
}

/// The Mac app's sidebar strip, as a phone's tab bar: the projects and their conversations, what waits for you across
/// them (◉ Status and the review rounds, badged with the count needing you), what they spent, and Settings.
struct RootTabs: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var projects = ProjectsModel.shared
    @Environment(\.horizontalSizeClass) private var width
    var body: some View {
        TabView {
            Group {
                // An iPad has room for the conversation beside the list; a phone, or a narrow window, does not.
                if width == .regular { SplitRoot() } else { NavigationRoot { ProjectsList() } }
            }
            .tabItem { Label("Projects", systemImage: "folder") }
            if store.supports("sessions") {
                NavigationRoot { FindingsScreen(repo: nil) }
                    .tabItem { Label("Findings", systemImage: "flag") }
                    .badge(projects.overview.needsYouCount)
            }
            if store.supports("usage") || store.supports("usage_all") || store.supports("providers") {
                NavigationRoot { UsageScreen() }
                    .tabItem { Label("Usage", systemImage: "chart.bar") }
            }
            NavigationRoot { SettingsScreen() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        // Every session's live stream, for as long as this connection lasts.
        .task(id: liveKey) { await SessionFeed.shared.follow() }
    }

    /// The connection and whether its server streams the sessions: a change of either opens the stream again.
    private var liveKey: String {
        guard let client = store.client else { return "" }
        return "\(ObjectIdentifier(client).hashValue):\(store.supports("events"))"
    }
}

struct PairingView: View {
    @EnvironmentObject private var store: Store
    @State private var token = ""
    private enum Field { case server, token }
    @FocusState private var focusedField: Field?
    private var canConnect: Bool { !store.connecting && !store.server.isEmpty && !token.isEmpty }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "square.stack.3d.up.fill").font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Theme.accent).frame(width: 52, height: 52)
                            .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityHidden(true)
                        Text("Connect to Briareus").font(.system(.largeTitle, design: .serif).weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                    }
                    .padding(.top, 32)
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(spacing: 0) {
                            HStack(spacing: 10) {
                                Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 20)
                                TextField("Server address", text: $store.server, prompt: Text(verbatim: "https://briareus.example.com"))
                                    .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
                                    .autocorrectionDisabled().accessibilityIdentifier("serverAddress")
                                    .focused($focusedField, equals: .server)
                                    .submitLabel(.next).onSubmit { focusedField = .token }
                            }.padding(.horizontal, 14).padding(.vertical, 14)
                            Divider().overlay(Theme.line).padding(.leading, 44)
                            HStack(spacing: 10) {
                                Image(systemName: "key").foregroundStyle(.secondary).frame(width: 20)
                                SecureField("Device token", text: $token)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .privacySensitive().accessibilityIdentifier("deviceToken")
                                    .focused($focusedField, equals: .token)
                                    .submitLabel(.done).onSubmit { focusedField = nil }
                            }.padding(.horizontal, 14).padding(.vertical, 14)
                        }
                        .background(Theme.raise, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line, lineWidth: 0.5))
                        Text("Issue a token on the server with `npm run create-token`.")
                            .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                    }
                    Button {
                        focusedField = nil
                        Task { await store.connect(server: store.server, token: token); if store.client != nil { token = "" } }
                    } label: {
                        HStack(spacing: 8) {
                            if store.connecting { ProgressView().tint(.white) }
                            Text(store.connecting ? "Connecting…" : "Connect").font(.body.weight(.semibold))
                        }
                        .foregroundStyle(canConnect || store.connecting ? Color.white : Color.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(canConnect || store.connecting ? Theme.accent : Theme.field, in: Capsule())
                    }
                    .buttonStyle(.plain).disabled(!canConnect)
                    .accessibilityIdentifier("connectButton")
                    if let error = store.connectionError {
                        ErrorNotice(message: error).padding(12)
                            .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(.horizontal, 20).frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.canvas)
        }
    }
}
