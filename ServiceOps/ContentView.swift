import AuthenticationServices
import SwiftUI

struct ContentView: View {
    @StateObject private var store = ServiceOpsStore()
    @AppStorage("serviceops.baseURL") private var baseURL = "https://serviceops.wijesundara.com"
    @State private var apiToken = ""
    @State private var hasSavedSession = SecureSessionStore.hasSession
    @State private var selectedTab: AppTab = .home
    @AppStorage("serviceops.biometricLockEnabled") private var biometricLockEnabled = false
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var notifications = PushNotificationCoordinator.shared

    @ViewBuilder
    var body: some View {
        if apiToken.isEmpty {
            MobileLoginView(
                baseURL: $baseURL,
                hasSavedSession: hasSavedSession,
                unlockSession: unlockSavedSession
            ) { response in
                try? SecureSessionStore.save(response.accessToken, account: "accessToken")
                try? SecureSessionStore.save(response.refreshToken, account: "refreshToken")
                hasSavedSession = true
                apiToken = response.accessToken
            }
        } else {
            TabView(selection: $selectedTab) {
            HomeView(store: store, baseURL: $baseURL, apiToken: $apiToken, selectedTab: $selectedTab)
                .tabItem { Label("Home", systemImage: "house") }
                .tag(AppTab.home)

            TicketsView(store: store, baseURL: $baseURL, apiToken: $apiToken)
                .tabItem { Label("My Work", systemImage: "checklist") }
                .tag(AppTab.work)

            NewIncidentView(store: store, baseURL: $baseURL, apiToken: $apiToken)
                .tabItem { Label("Create", systemImage: "plus.circle") }
                .tag(AppTab.create)

            NotificationInboxView(baseURL: baseURL, token: apiToken) { ticket in
                TicketDetailView(ticket: ticket, store: store, baseURL: $baseURL, apiToken: $apiToken)
            }
                .tabItem { Label("Inbox", systemImage: "bell") }
                .badge(notifications.unreadCount)
                .tag(AppTab.inbox)

            MobileMoreView(store: store, baseURL: $baseURL, apiToken: $apiToken,
                           biometricLockEnabled: $biometricLockEnabled) {
                Task {
                    if let access = SecureSessionStore.read(account: "accessToken"),
                       let client = try? ServiceOpsAPIClient(baseURLString: baseURL, token: access) {
                        try? await client.unregisterPushDevice(deviceId: notifications.deviceID)
                        try? await client.logout()
                    }
                    SecureSessionStore.clear()
                    apiToken = ""
                    hasSavedSession = false
                    store.signOut()
                }
            }
                .tabItem { Label("More", systemImage: "square.grid.2x2") }
                .tag(AppTab.more)
            }
            .tint(ServiceOpsTheme.nowGreen)
            // One alert for the shared store error. Every tab stays alive in the TabView, so
            // per-screen alerts on the same state presented together and fought on dismissal.
            .serviceOpsAlert(store: store)
            // The inbox resolves and opens a tapped push notification's target.
            .onChange(of: notifications.pendingTarget, initial: true) { _, target in
                if target != nil { selectedTab = .inbox }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background, biometricLockEnabled {
                    apiToken = ""
                    hasSavedSession = SecureSessionStore.hasSession
                }
            }
            .task { await loadBootstrap() }
            .task { await configurePushNotifications() }
        }
    }

    /// Loads the signed-in user's capabilities and badge counts, independent of
    /// push registration (simulators and denied-permission devices have no token).
    private func loadBootstrap() async {
        if let unread = await store.loadBootstrap(baseURL: baseURL, token: apiToken) {
            notifications.unreadCount = unread
        }
    }

    private func configurePushNotifications() async {
        await notifications.requestAuthorization()
        guard let token = notifications.deviceToken else { return }
        do {
            let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: apiToken)
            try await client.registerPushDevice(
                token: token, deviceId: notifications.deviceID,
                environment: pushEnvironment
            )
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private var pushEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    private func unlockSavedSession() async throws {
        apiToken = try await SecureSessionStore.unlockAccessToken()
        hasSavedSession = SecureSessionStore.hasSession
    }
}

private struct MobileLoginView: View {
    /// A sign-in attempt that the server accepted except for the MFA code.
    private enum PendingVerification {
        case password
        case cloudflareAccess(assertion: String)
    }

    /// Why the Cloudflare Access sheet is shown: to pass an Access gate in front of the
    /// API, or to sign in to ServiceOps with the Access identity.
    private enum AccessPurpose: Identifiable {
        case gate(host: String)
        case identity(host: String)
        var id: String {
            switch self {
            case .gate(let host): "gate-\(host)"
            case .identity(let host): "identity-\(host)"
            }
        }
        var host: String {
            switch self {
            case .gate(let host), .identity(let host): host
            }
        }
    }

    @Binding var baseURL: String
    let hasSavedSession: Bool
    let unlockSession: () async throws -> Void
    let authenticated: (MobileAuthResponse) -> Void
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @AppStorage("serviceops.lastPasswordProvider") private var lastPasswordProvider = "local"
    @State private var methods: MobileAuthMethods?
    @State private var isDiscovering = false
    @State private var accessGateHost: String?
    @State private var accessPurpose: AccessPurpose?
    @State private var username = ""
    @State private var password = ""
    @State private var mfaCode = ""
    @State private var provider = "local"
    @State private var pendingVerification: PendingVerification?
    @State private var isBusy = false
    @State private var localAuthenticationLabel = SecureSessionStore.localAuthenticationLabel()
    @State private var errorMessage: String?
    @FocusState private var mfaFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    serverStatus
                } header: {
                    Text("ServiceOps server")
                }

                if pendingVerification != nil {
                    verificationSection
                } else if accessGateHost == nil {
                    if hasSavedSession {
                        Section("Quick access") {
                            Button {
                                Task { await unlockWithLocalAuthentication() }
                            } label: {
                                Label(localAuthenticationLabel, systemImage: "faceid")
                            }
                            .disabled(isBusy)
                        }
                    }
                    if let methods {
                        signInSections(for: methods)
                    }
                }

                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle("ServiceOps")
            .disabled(isBusy)
            .overlay { if isBusy { ProgressView().controlSize(.large) } }
            .onAppear { localAuthenticationLabel = SecureSessionStore.localAuthenticationLabel() }
            .task(id: baseURL) {
                // Debounce typing in the server field before probing the server.
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await discoverMethods()
            }
            .sheet(item: $accessPurpose) { purpose in
                CloudflareAccessSignInView(host: purpose.host) { token in
                    accessPurpose = nil
                    guard let token else { return }
                    CloudflareAccessSession.save(token, for: purpose.host)
                    Task {
                        switch purpose {
                        case .gate: await discoverMethods()
                        case .identity: await completeCloudflareAccessSignIn(assertion: token)
                        }
                    }
                }
                .interactiveDismissDisabled()
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var serverStatus: some View {
        if isDiscovering {
            Label("Checking server…", systemImage: "antenna.radiowaves.left.and.right")
                .font(.footnote).foregroundStyle(.secondary)
        } else if let host = accessGateHost {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(host) is protected by Cloudflare Access.", systemImage: "lock.shield")
                    .font(.footnote)
                Button("Sign in to Cloudflare Access") { accessPurpose = .gate(host: host) }
            }
        }
    }

    @ViewBuilder
    private func signInSections(for methods: MobileAuthMethods) -> some View {
        if methods.keycloak || methods.cloudflareAccess || methods.passkeys {
            Section("Single sign-on") {
                if methods.keycloak {
                    Button { Task { await signInWithKeycloak() } } label: {
                        Label("Sign in with your organization", systemImage: "building.2")
                    }
                }
                if methods.cloudflareAccess {
                    Button { Task { await signInWithCloudflareAccess() } } label: {
                        Label("Continue with Cloudflare Access", systemImage: "lock.shield")
                    }
                }
                if methods.passkeys {
                    Button { Task { await signInWithPasskey() } } label: {
                        Label("Continue with Passkey", systemImage: "person.badge.key.fill")
                    }
                }
            }
        }
        if methods.password {
            Section("Sign in with password") {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                if methods.local && methods.ldap {
                    Picker("Account type", selection: $provider) {
                        Text("Local account").tag("local")
                        Text("Directory / LDAP").tag("ldap")
                    }
                }
                Button("Sign in") { Task { await signInWithPassword() } }
                    .disabled(username.isEmpty || password.isEmpty)
            }
        }
        if !methods.password && !methods.keycloak && !methods.cloudflareAccess && !methods.passkeys {
            Section {
                Text("This server doesn't offer any sign-in method for the mobile app. Contact your ServiceOps administrator.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var verificationSection: some View {
        Section {
            TextField("Authentication or backup code", text: $mfaCode)
                .textContentType(.oneTimeCode)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($mfaFieldFocused)
                .onSubmit { Task { await submitVerification() } }
            Button("Verify") { Task { await submitVerification() } }
                .disabled(mfaCode.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {
                pendingVerification = nil
                mfaCode = ""
                errorMessage = nil
            }
        } header: {
            Text("Two-step verification")
        } footer: {
            Text("Enter the code from your authenticator app, or one of your backup codes.")
        }
    }

    // MARK: Discovery

    private func discoverMethods() async {
        isDiscovering = true
        defer { isDiscovering = false }
        do {
            let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: "")
            let discovered = try await client.authMethods() ?? .legacy
            accessGateHost = nil
            methods = discovered
            errorMessage = nil
            selectDefaultProvider(for: discovered)
        } catch ServiceOpsAPIError.accessRequired(let host) {
            accessGateHost = host
            methods = nil
        } catch {
            // Unreachable or misconfigured: still offer the classic methods so the
            // user can try, and show why discovery failed.
            accessGateHost = nil
            methods = .legacy
            selectDefaultProvider(for: .legacy)
            if !baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
                errorMessage = Self.message(for: error)
            }
        }
    }

    /// Prefers the account type that last worked, when the server still allows it.
    private func selectDefaultProvider(for methods: MobileAuthMethods) {
        let allowed = [methods.local ? "local" : nil, methods.ldap ? "ldap" : nil].compactMap { $0 }
        provider = allowed.contains(lastPasswordProvider) ? lastPasswordProvider : (allowed.first ?? "local")
    }

    // MARK: Sign-in methods

    private func signInWithPassword() async {
        await run(retry: .password) {
            let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: "")
            let response = try await client.login(username: username, password: password, provider: provider,
                                                  mfaCode: currentMFACode)
            lastPasswordProvider = provider
            return response
        }
    }

    private func signInWithCloudflareAccess() async {
        guard let host = URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host else {
            errorMessage = "Enter a valid ServiceOps server URL."
            return
        }
        if let token = CloudflareAccessSession.token(for: host) {
            await completeCloudflareAccessSignIn(assertion: token)
        } else {
            accessPurpose = .identity(host: host)
        }
    }

    private func completeCloudflareAccessSignIn(assertion: String) async {
        await run(retry: .cloudflareAccess(assertion: assertion)) {
            let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: "")
            return try await client.loginWithCloudflareAccess(assertion: assertion, mfaCode: currentMFACode)
        }
    }

    private func signInWithKeycloak() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: "")
            let pkce = PKCEChallenge()
            let startURL = try client.keycloakStartURL(codeChallenge: pkce.challenge, state: pkce.state)
            let callbackURL = try await webAuthenticationSession.authenticate(
                using: startURL, callbackURLScheme: "serviceops", preferredBrowserSession: .shared
            )
            let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value }
            guard value("state") == pkce.state else {
                throw ServiceOpsAPIError.transport("The sign-in response didn't match this request. Try again.")
            }
            if let failure = value("error") {
                throw ServiceOpsAPIError.transport(Self.keycloakMessage(for: failure))
            }
            guard let code = value("code") else {
                throw ServiceOpsAPIError.transport("Your organization didn't complete the sign-in. Try again.")
            }
            authenticated(try await client.exchangeKeycloakCode(code, verifier: pkce.verifier))
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private func signInWithPasskey() async {
        isBusy = true
        defer { isBusy = false }
        do {
            authenticated(try await PasskeyManager().authenticate(baseURL: baseURL))
        } catch let error as ASAuthorizationError where error.code == .canceled {
            return
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private func unlockWithLocalAuthentication() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await unlockSession()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: MFA step-up

    private var currentMFACode: String? {
        guard pendingVerification != nil else { return nil }
        let code = mfaCode.trimmingCharacters(in: .whitespaces)
        return code.isEmpty ? nil : code
    }

    private func submitVerification() async {
        switch pendingVerification {
        case .password: await signInWithPassword()
        case .cloudflareAccess(let assertion): await completeCloudflareAccessSignIn(assertion: assertion)
        case nil: break
        }
    }

    /// Runs a sign-in attempt and switches to the next step the server asks for:
    /// an MFA code, a Cloudflare Access sign-in, or an error message.
    private func run(retry: PendingVerification, _ attempt: () async throws -> MobileAuthResponse) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await attempt()
            pendingVerification = nil
            mfaCode = ""
            errorMessage = nil
            authenticated(response)
        } catch let error as ServiceOpsAPIError {
            switch Self.mfaState(of: error) {
            case .required where pendingVerification == nil:
                pendingVerification = retry
                errorMessage = nil
                mfaFieldFocused = true
            case .required, .invalid:
                // Already asked once: the code that was entered wasn't accepted.
                pendingVerification = retry
                mfaCode = ""
                errorMessage = "That code wasn't accepted. Check your authenticator app and try again."
                mfaFieldFocused = true
            case nil:
                if case .accessRequired(let host) = error {
                    pendingVerification = nil
                    accessGateHost = host
                    methods = nil
                } else if error.serverCode == "access_identity_missing", let host = URL(string: baseURL)?.host {
                    CloudflareAccessSession.clear(for: host)
                    pendingVerification = nil
                    errorMessage = "Your Cloudflare Access sign-in has expired. Continue with Cloudflare Access again."
                } else {
                    errorMessage = Self.message(for: error)
                }
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private enum MFAState { case required, invalid }

    /// Uses the server's error code, falling back to its message on servers that predate codes.
    private static func mfaState(of error: ServiceOpsAPIError) -> MFAState? {
        switch error.serverCode {
        case "mfa_required": return .required
        case "mfa_invalid": return .invalid
        case nil where error.statusCode == 401 && (error.serverMessage ?? "").contains("MFA or backup code"):
            return .required
        default: return nil
        }
    }

    private static func message(for error: Error) -> String {
        if let apiError = error as? ServiceOpsAPIError, let message = apiError.serverMessage {
            return message
        }
        return error.localizedDescription
    }

    private static func keycloakMessage(for code: String) -> String {
        switch code {
        case "access_denied": "Sign-in was cancelled or refused by your organization."
        case "mfa_assurance": "Your organization didn't confirm multi-factor authentication. Sign in again with MFA."
        case "link_refused": "An account with your email already exists. Verify your email with your organization, or ask an administrator to link the account."
        case "inactive": "This account or its organization is not active."
        default: "Single sign-on couldn't be completed. Try again."
        }
    }
}

enum AppTab: Hashable {
    case home
    case work
    case create
    case inbox
    case more
}

/// Destinations reachable from Home widgets.
private enum HomeRoute: Hashable {
    case tickets(TicketScope)
    case approvals
    case knowledge
    case assets
    case dashboards
    case projects
}

private struct HomeView: View {
    @ObservedObject var store: ServiceOpsStore
    @Binding var baseURL: String
    @Binding var apiToken: String
    @Binding var selectedTab: AppTab

    /// Most recently updated first, so "Recent" means what it says. Falls back to comparing
    /// the raw timestamps when the server sends a format the ISO parser doesn't accept.
    private var recentTickets: [ServiceTicket] {
        let sorted = store.tickets.sorted { lhs, rhs in
            if let left = ServiceOpsDate.date(from: lhs.updatedAt), let right = ServiceOpsDate.date(from: rhs.updatedAt) {
                return left > right
            }
            return lhs.updatedAt > rhs.updatedAt
        }
        return Array(sorted.prefix(4))
    }

    /// `nil` until the first load finishes, so cards show a placeholder instead of a false 0.
    private func count(_ scope: TicketScope) -> String? {
        store.tickets.isEmpty && store.isLoadingTickets ? nil : String(store.tickets(in: scope).count)
    }

    private var groupSubtitle: String {
        switch store.assignmentGroups.count {
        case 0: "No assignment groups"
        case 1: store.assignmentGroups[0].name
        default: "\(store.assignmentGroups.count) assignment groups"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ServiceOpsTheme.nowBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        MobileHomeHeader(
                            profile: store.profile,
                            avatar: store.avatarImage,
                            openCount: store.tickets(in: .open).count,
                            isLoading: store.isLoadingTickets,
                            openAccount: { selectedTab = .more },
                            refresh: { Task { await refresh() } }
                        )

                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("Your work")
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                                NavigationLink(value: HomeRoute.tickets(.assignedToMe)) {
                                    AppletCard(title: "My Work", subtitle: "Assigned to you",
                                               value: count(.assignedToMe), icon: "checklist", color: ServiceOpsTheme.nowGreen)
                                }
                                NavigationLink(value: HomeRoute.tickets(.myGroups)) {
                                    AppletCard(title: "My Group's Work", subtitle: groupSubtitle,
                                               value: count(.myGroups), icon: "person.3.fill", color: ServiceOpsTheme.blue)
                                }
                                NavigationLink(value: HomeRoute.tickets(.majorIncidents)) {
                                    AppletCard(title: "Major Incidents", subtitle: "Open P1 incidents",
                                               value: count(.majorIncidents), icon: "exclamationmark.triangle.fill", color: .red)
                                }
                                NavigationLink(value: HomeRoute.approvals) {
                                    AppletCard(title: "My Approvals", subtitle: "Waiting for your decision",
                                               value: store.pendingApprovals.map(String.init), icon: "hand.thumbsup.fill",
                                               color: ServiceOpsTheme.purple)
                                }
                            }
                            .buttonStyle(PressableCardStyle())
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("Quick actions")
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                                if store.capabilities?.createIncident != false {
                                    Button { selectedTab = .create } label: {
                                        QuickActionLabel(title: "Report issue", icon: "plus.message.fill")
                                    }
                                }
                                NavigationLink(value: HomeRoute.dashboards) {
                                    QuickActionLabel(title: "Dashboards", icon: "rectangle.3.group.fill")
                                }
                                NavigationLink(value: HomeRoute.projects) {
                                    QuickActionLabel(title: "Projects", icon: "square.stack.3d.up.fill")
                                }
                                if store.capabilities?.viewCmdb == true {
                                    NavigationLink(value: HomeRoute.assets) {
                                        QuickActionLabel(title: "Assets", icon: "server.rack")
                                    }
                                }
                                NavigationLink(value: HomeRoute.knowledge) {
                                    QuickActionLabel(title: "Knowledge", icon: "book.closed.fill")
                                }
                            }
                            .buttonStyle(PressableCardStyle())
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                SectionLabel("Recently updated")
                                Spacer()
                                Button("View all") { selectedTab = .work }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(ServiceOpsTheme.nowGreen)
                            }

                            VStack(spacing: 0) {
                                if recentTickets.isEmpty && store.isLoadingTickets {
                                    ProgressView("Loading records")
                                        .frame(maxWidth: .infinity, minHeight: 120)
                                } else if recentTickets.isEmpty {
                                    ContentUnavailableView("No records", systemImage: "tray")
                                        .frame(minHeight: 150)
                                } else {
                                    ForEach(recentTickets) { ticket in
                                        NavigationLink(value: ticket) {
                                            MobileRecordCard(ticket: ticket)
                                        }
                                        .buttonStyle(.plain)
                                        if ticket.id != recentTickets.last?.id {
                                            Divider().padding(.leading, 68)
                                        }
                                    }
                                }
                            }
                            .background(ServiceOpsTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(ServiceOpsTheme.nowLine))
                        }
                    }
                    .padding(18)
                }
                .refreshable { await refresh() }
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .tickets(let scope):
                    ScopedTicketsView(scope: scope, store: store, baseURL: $baseURL, apiToken: $apiToken)
                case .approvals:
                    ApprovalsView(baseURL: baseURL, token: apiToken)
                        // Decisions made there change the pending count on this card.
                        .onDisappear { Task { await refreshBootstrap() } }
                case .knowledge:
                    KnowledgeView(baseURL: baseURL, token: apiToken)
                case .assets:
                    CMDBView(baseURL: baseURL, token: apiToken)
                case .dashboards:
                    DashboardsView(store: store, baseURL: $baseURL, apiToken: $apiToken)
                case .projects:
                    ProjectsView(baseURL: baseURL, token: apiToken)
                }
            }
            .navigationDestination(for: ServiceTicket.self) { ticket in
                TicketDetailView(ticket: ticket, store: store, baseURL: $baseURL, apiToken: $apiToken)
            }
            .task {
                if store.tickets.isEmpty {
                    await store.loadTickets(baseURL: baseURL, token: apiToken, filter: .all)
                }
            }
        }
    }

    private func refresh() async {
        await store.loadTickets(baseURL: baseURL, token: apiToken, filter: .all)
        await refreshBootstrap()
    }

    private func refreshBootstrap() async {
        if let unread = await store.loadBootstrap(baseURL: baseURL, token: apiToken) {
            PushNotificationCoordinator.shared.unreadCount = unread
        }
    }
}

/// The list behind a Home card: the same filter the card counted.
private struct ScopedTicketsView: View {
    let scope: TicketScope
    @ObservedObject var store: ServiceOpsStore
    @Binding var baseURL: String
    @Binding var apiToken: String

    var body: some View {
        ZStack {
            ServiceOpsTheme.nowBackground.ignoresSafeArea()

            ScrollView {
                TicketListPanel(
                    title: scope.title,
                    subtitle: scope.subtitle,
                    tickets: store.tickets(in: scope),
                    apiToken: apiToken,
                    isLoading: store.isLoadingTickets
                ) { ticket in
                    TicketDetailView(ticket: ticket, store: store, baseURL: $baseURL, apiToken: $apiToken)
                }
                .padding(16)
            }
            .refreshable {
                await store.loadTickets(baseURL: baseURL, token: apiToken, filter: .all)
            }
        }
        .navigationTitle(scope.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TicketsView: View {
    @ObservedObject var store: ServiceOpsStore
    @Binding var baseURL: String
    @Binding var apiToken: String
    @State private var filter: TicketTypeFilter = .all
    @State private var scope: TicketScope?
    @State private var searchText = ""

    /// The tiles above the list; each one filters it.
    private let filterTiles: [(scope: TicketScope, label: String, icon: String, color: Color)] = [
        (.open, "Open", "tray.full", ServiceOpsTheme.green),
        (.highRisk, "High risk", "exclamationmark.triangle", .red),
        (.assignedToMe, "Mine", "person.crop.circle", ServiceOpsTheme.amber)
    ]

    private var visibleTickets: [ServiceTicket] {
        let scoped = scope.map { store.tickets(in: $0) } ?? store.tickets
        guard !searchText.isEmpty else { return scoped }
        return scoped.filter { ticket in
            ticket.number.localizedCaseInsensitiveContains(searchText)
            || ticket.title.localizedCaseInsensitiveContains(searchText)
            || ticket.state.localizedCaseInsensitiveContains(searchText)
            || ticket.priority.localizedCaseInsensitiveContains(searchText)
            || ticket.assignmentGroupName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ServiceOpsTheme.nowBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        HStack(spacing: 10) {
                            ForEach(filterTiles, id: \.scope) { tile in
                                FilterTile(
                                    label: tile.label,
                                    value: store.tickets(in: tile.scope).count,
                                    icon: tile.icon,
                                    color: tile.color,
                                    isSelected: scope == tile.scope
                                ) {
                                    withAnimation(.snappy) { scope = scope == tile.scope ? nil : tile.scope }
                                }
                            }
                        }

                        Picker("Type", selection: $filter) {
                            ForEach(TicketTypeFilter.allCases) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)

                        TicketListPanel(
                            title: scope?.title ?? "All records",
                            subtitle: scope?.subtitle ?? "\(store.tickets.count) visible incidents and changes",
                            tickets: visibleTickets,
                            apiToken: apiToken,
                            isLoading: store.isLoadingTickets,
                            clearFilter: scope == nil ? nil : { withAnimation(.snappy) { scope = nil } }
                        ) { ticket in
                            TicketDetailView(ticket: ticket, store: store, baseURL: $baseURL, apiToken: $apiToken)
                        }
                    }
                    .padding(16)
                }
                .refreshable {
                    await store.loadTickets(baseURL: baseURL, token: apiToken, filter: filter)
                }
            }
            .navigationTitle("My Work")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if store.isLoadingTickets {
                        ProgressView()
                    } else {
                        Button {
                            Task { await store.loadTickets(baseURL: baseURL, token: apiToken, filter: filter) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Number or short description")
            .task {
                if store.tickets.isEmpty {
                    await store.loadTickets(baseURL: baseURL, token: apiToken, filter: filter)
                }
            }
            .onChange(of: filter) { _, newFilter in
                Task { await store.loadTickets(baseURL: baseURL, token: apiToken, filter: newFilter) }
            }
        }
    }
}

/// A count tile on My Work that toggles its filter on the list below.
private struct FilterTile: View {
    let label: String
    let value: Int
    let icon: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isSelected ? .white : color)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                    }
                }
                Text("\(value)")
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? .white : ServiceOpsTheme.ink)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? .white.opacity(0.9) : ServiceOpsTheme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(isSelected ? AnyShapeStyle(color.gradient) : AnyShapeStyle(ServiceOpsTheme.surface),
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(isSelected ? color : ServiceOpsTheme.nowLine))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
        .accessibilityHint(isSelected ? "Shows all records" : "Filters the list")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct TicketListPanel<Destination: View>: View {
    var title = "All records"
    var subtitle = "All visible incidents and changes"
    let tickets: [ServiceTicket]
    let apiToken: String
    let isLoading: Bool
    var clearFilter: (() -> Void)?
    let destination: (ServiceTicket) -> Destination

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(ServiceOpsTheme.tealText)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let clearFilter {
                    Button("Clear", action: clearFilter)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Clear filter")
                }
            }
            .padding(14)
            .background(ServiceOpsTheme.toolbarBackground)

            Divider()

            if isLoading && tickets.isEmpty {
                ProgressView("Loading records")
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else if tickets.isEmpty {
                ContentUnavailableView(
                    "No matching records",
                    systemImage: apiToken.isEmpty ? "key.slash" : "tray",
                    description: Text(apiToken.isEmpty ? "API token missing." : "Try a different search or filter.")
                )
                .frame(minHeight: 260)
            } else {
                LazyVStack(spacing: 0) {
                    TableHeaderRow()
                    ForEach(tickets) { ticket in
                        NavigationLink {
                            destination(ticket)
                        } label: {
                            TicketRow(ticket: ticket)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
        .background(ServiceOpsTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ServiceOpsTheme.nowLine))
    }
}

private struct MobileHomeHeader: View {
    let profile: MobileProfile?
    let avatar: UIImage?
    let openCount: Int
    let isLoading: Bool
    let openAccount: () -> Void
    let refresh: () -> Void

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    private var summary: String {
        [profile?.role.capitalized, "\(openCount) open records"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: openAccount) {
                ProfileAvatar(name: profile?.name, image: avatar, size: 56, onDarkBackground: true)
                    .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 2))
            }
            .buttonStyle(PressableCardStyle())
            .accessibilityLabel("Account")
            .accessibilityHint("Opens your account and settings")

            VStack(alignment: .leading, spacing: 3) {
                Text(greeting)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                Text(profile?.name ?? "ServiceOps")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button(action: refresh) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.headline)
                }
            }
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(.white.opacity(0.14), in: Circle())
            .disabled(isLoading)
            .accessibilityLabel("Refresh")
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [ServiceOpsTheme.nowGreenDark, ServiceOpsTheme.nowGreen],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22)
        )
        .shadow(color: ServiceOpsTheme.nowGreen.opacity(0.22), radius: 20, y: 10)
    }
}

/// The user's profile picture, or their initials when none has been uploaded.
private struct ProfileAvatar: View {
    let name: String?
    let image: UIImage?
    var size: CGFloat = 44
    var onDarkBackground = false

    private var initials: String {
        let letters = (name ?? "").split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(onDarkBackground ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(ServiceOpsTheme.nowGreen.gradient))
                    Text(initials)
                        .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

private struct SectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(ServiceOpsTheme.ink)
    }
}

/// Press feedback for card-style buttons and links, so they read as tappable.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// A Home card's content; the caller wraps it in the link it opens.
private struct AppletCard: View {
    let title: String
    let subtitle: String
    let value: String?
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(color)
                    .frame(width: 38, height: 38)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                Spacer()
                Text(value ?? "–")
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(ServiceOpsTheme.ink)
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 0)

            HStack(alignment: .bottom, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(ServiceOpsTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(ServiceOpsTheme.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .background(ServiceOpsTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(ServiceOpsTheme.nowLine))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}

/// A quick action's content; the caller wraps it in a button or link.
private struct QuickActionLabel: View {
    let title: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(ServiceOpsTheme.nowGreen)
                .frame(width: 42, height: 42)
                .background(ServiceOpsTheme.nowGreen.opacity(0.12), in: Circle())
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ServiceOpsTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(ServiceOpsTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(ServiceOpsTheme.nowLine))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct MobileRecordCard: View {
    let ticket: ServiceTicket

    var body: some View {
        HStack(spacing: 12) {
            RecordTypeIcon(kind: ticket.type)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(ticket.number)
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(ServiceOpsTheme.greenText)
                    PriorityDot(priority: ticket.priority)
                    Text(ticket.priority)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(ServiceOpsTheme.muted)
                }
                Text(ticket.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ServiceOpsTheme.ink)
                    .lineLimit(2)
                Text("\(ticket.state) · \(ticket.assignmentGroupName)")
                    .font(.caption)
                    .foregroundStyle(ServiceOpsTheme.muted)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }
}

struct TableHeaderRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Number")
                .frame(width: 104, alignment: .leading)
            Text("Short description")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("State")
                .frame(width: 86, alignment: .leading)
        }
        .font(.caption2.weight(.bold))
        .textCase(.uppercase)
        .foregroundStyle(ServiceOpsTheme.ink.opacity(0.72))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ServiceOpsTheme.headerBackground)
    }
}

struct TicketRow: View {
    let ticket: ServiceTicket

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(ticket.number)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(ServiceOpsTheme.tealText)
                HStack(spacing: 6) {
                    PriorityDot(priority: ticket.priority)
                    Text(ticket.priority)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ServiceOpsTheme.muted)
                }
            }
            .frame(width: 104, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                Text(ticket.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ServiceOpsTheme.ink)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    Label(ticket.assignmentGroupName, systemImage: "person.3")
                    Label(ticket.assigneeName, systemImage: "person.crop.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            StateBadge(state: ticket.state)
                .frame(width: 86, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

struct TicketDetailView: View {
    let ticket: ServiceTicket
    @ObservedObject var store: ServiceOpsStore
    @Binding var baseURL: String
    @Binding var apiToken: String
    @State private var selectedState: String
    @State private var selectedPriority: String

    init(ticket: ServiceTicket, store: ServiceOpsStore, baseURL: Binding<String>, apiToken: Binding<String>) {
        self.ticket = ticket
        self.store = store
        self._baseURL = baseURL
        self._apiToken = apiToken
        self._selectedState = State(initialValue: ticket.state)
        self._selectedPriority = State(initialValue: ticket.priority)
    }

    private var displayedTicket: ServiceTicket {
        store.selectedTicket?.id == ticket.id ? store.selectedTicket ?? ticket : ticket
    }

    private var hasResolutionInformation: Bool {
        displayedTicket.resolvedAt != nil
            || nonempty(displayedTicket.resolutionNotes) != nil
            || nonempty(displayedTicket.closureCategory) != nil
            || nonempty(displayedTicket.closureSubcategory) != nil
    }

    var body: some View {
        ZStack {
            ServiceOpsTheme.nowBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    RecordToolbar(ticket: displayedTicket, isSaving: store.isSaving, canSave: hasChanges && displayedTicket.details?.canManage != false) {
                        Task { await saveChanges() }
                    }

                    if let message = store.errorMessage {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .font(.subheadline).foregroundStyle(.red)
                            Button("Retry loading ticket") {
                                Task { await store.refreshTicket(ticket, baseURL: baseURL, token: apiToken) }
                            }
                        }
                    }

                    StateTrack(currentState: displayedTicket.state)

                    RecordPanel {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(displayedTicket.title)
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(ServiceOpsTheme.ink)
                                    Text(displayedTicket.description)
                                        .font(.subheadline)
                                        .foregroundStyle(ServiceOpsTheme.muted)
                                }
                                Spacer()
                                PriorityBadge(priority: displayedTicket.priority)
                            }

                            Divider()

                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                                FactCell(label: "Type", value: displayedTicket.type.rawValue.capitalized, icon: "square.stack.3d.up")
                                FactCell(label: "State", value: displayedTicket.state, icon: "point.3.connected.trianglepath.dotted")
                                FactCell(label: "Priority", value: displayedTicket.priority, icon: "exclamationmark.triangle")
                                FactCell(label: "Category", value: displayedTicket.category, icon: "tag")
                                FactCell(label: "Subcategory", value: displayedTicket.subcategory.flatMap { $0.isEmpty ? nil : $0 } ?? "Not recorded", icon: "tag.fill")
                                FactCell(label: "Assignment group", value: displayedTicket.assignmentGroupName, icon: "person.3")
                                FactCell(label: "Assigned to", value: displayedTicket.assigneeName, icon: "person.crop.circle")
                                FactCell(label: "Opened", value: ServiceOpsDate.format(displayedTicket.openedAt), icon: "calendar")
                                FactCell(label: "Updated", value: ServiceOpsDate.format(displayedTicket.updatedAt), icon: "clock")
                                if let resolvedAt = displayedTicket.resolvedAt {
                                    FactCell(label: "Resolved", value: ServiceOpsDate.format(resolvedAt), icon: "checkmark.circle")
                                }
                            }
                        }
                    }

                    if let details = displayedTicket.details {
                        TicketInformationView(details: details, baseURL: baseURL, token: apiToken)
                    } else if store.errorMessage == nil {
                        Text("Additional ticket information requires a ServiceOps server that publishes ticket details.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if hasResolutionInformation {
                        RecordPanel(title: "Resolution information", subtitle: "Closure details from the ticket") {
                            VStack(alignment: .leading, spacing: 12) {
                                LabeledContent("Closure category", value: nonempty(displayedTicket.closureCategory) ?? "Not recorded")
                                LabeledContent("Closure subcategory", value: nonempty(displayedTicket.closureSubcategory) ?? "Not recorded")
                                if let notes = nonempty(displayedTicket.resolutionNotes) {
                                    Divider()
                                    Text("Resolution notes")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(ServiceOpsTheme.muted)
                                    Text(notes)
                                        .font(.subheadline)
                                        .foregroundStyle(ServiceOpsTheme.ink)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    if displayedTicket.details?.canManage == false {
                        Label("This ticket is read-only for your account.", systemImage: "lock")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    RecordPanel(title: "Update record", subtitle: "State and priority") {
                        VStack(spacing: 14) {
                            Picker("State", selection: $selectedState) {
                                ForEach(displayedTicket.details.map { $0.allowedStates.contains(displayedTicket.state) ? $0.allowedStates : [displayedTicket.state] + $0.allowedStates } ?? TicketState.options(from: displayedTicket.state), id: \.self) { state in
                                    Text(state).tag(state)
                                }
                            }
                            Picker("Priority", selection: $selectedPriority) {
                                ForEach(ServiceOpsPriority.allCases) { priority in
                                    Text(priority.label).tag(priority.rawValue)
                                }
                            }
                            Button {
                                Task { await saveChanges() }
                            } label: {
                                if store.isSaving {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Label("Save changes", systemImage: "checkmark.circle.fill")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            // The server rejects an empty PATCH body, so require an actual edit.
                            .disabled(store.isSaving || !hasChanges || displayedTicket.details?.canManage == false)
                        }
                    }

                    if displayedTicket.type == .change {
                        ChangeTasksView(number: displayedTicket.number, baseURL: baseURL, token: apiToken,
                                        canManage: store.capabilities?.manageTickets ?? false)
                    }

                    TicketAttachmentsView(number: displayedTicket.number, baseURL: baseURL, token: apiToken)

                    TicketCommentsView(number: displayedTicket.number, baseURL: baseURL, token: apiToken)
                }
                .padding(16)
            }
        }
        .navigationTitle(displayedTicket.number)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refreshTicket(ticket, baseURL: baseURL, token: apiToken) }
        .task {
            await store.refreshTicket(ticket, baseURL: baseURL, token: apiToken)
        }
        .onChange(of: store.selectedTicket) { _, updatedTicket in
            guard updatedTicket?.id == ticket.id else { return }
            selectedState = updatedTicket?.state ?? selectedState
            selectedPriority = updatedTicket?.priority ?? selectedPriority
        }
    }

    private var hasChanges: Bool {
        selectedState != displayedTicket.state || selectedPriority != displayedTicket.priority
    }

    private func nonempty(_ value: String?) -> String? {
        value.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    private func saveChanges() async {
        _ = await store.updateTicket(
            displayedTicket,
            state: selectedState,
            priority: selectedPriority,
            baseURL: baseURL,
            token: apiToken
        )
    }
}

private struct NewIncidentView: View {
    @ObservedObject var store: ServiceOpsStore
    @Binding var baseURL: String
    @Binding var apiToken: String
    @AppStorage("serviceops.assignmentGroupID") private var assignmentGroupID = "5"
    @State private var title = ""
    @State private var description = ""
    @State private var category = "General"
    @State private var priority = ServiceOpsPriority.p3.rawValue
    @State private var createdTicket: ServiceTicket?

    private let categories = ["General", "Access", "Hardware", "Software", "Network", "Security"]

    var body: some View {
        NavigationStack {
            ZStack {
                ServiceOpsTheme.nowBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        WorkspaceHeader(
                            title: "New incident",
                            subtitle: "Create an INC record",
                            systemImage: "plus.circle",
                            isLoading: store.isSaving,
                            action: nil
                        )

                        RecordPanel(title: "Incident", subtitle: "Required fields") {
                            VStack(spacing: 14) {
                                FloatingField(title: "Short description", text: $title, axis: .horizontal)
                                FloatingField(title: "Description", text: $description, axis: .vertical)

                                Picker("Category", selection: $category) {
                                    ForEach(categories, id: \.self) { category in
                                        Text(category).tag(category)
                                    }
                                }
                                .pickerStyle(.menu)

                                Picker("Priority", selection: $priority) {
                                    ForEach(ServiceOpsPriority.allCases) { priority in
                                        Text(priority.label).tag(priority.rawValue)
                                    }
                                }
                                .pickerStyle(.segmented)

                                FloatingField(title: "Assignment group ID", text: $assignmentGroupID, axis: .horizontal)
                                    .keyboardType(.numberPad)
                            }
                        }

                        Button {
                            Task { await createIncident() }
                        } label: {
                            if store.isSaving {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Label("Create incident", systemImage: "plus.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!canSubmit || store.isSaving)

                        if let createdTicket {
                            RecordPanel(title: "Created", subtitle: createdTicket.number) {
                                TicketRow(ticket: createdTicket)
                                    .padding(.horizontal, -16)
                                    .padding(.vertical, -10)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("New")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && Int(assignmentGroupID) != nil
    }

    private func createIncident() async {
        guard let groupID = Int(assignmentGroupID) else { return }
        let draft = IncidentDraft(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            priority: priority,
            assignmentGroupId: groupID
        )
        let success = await store.createIncident(draft, baseURL: baseURL, token: apiToken)
        if success, let created = store.selectedTicket {
            createdTicket = created
            title = ""
            description = ""
            category = "General"
            priority = ServiceOpsPriority.p3.rawValue
        }
    }
}

private struct MobileMoreView: View {
    @ObservedObject var store: ServiceOpsStore
    @Binding var baseURL: String
    @Binding var apiToken: String
    @Binding var biometricLockEnabled: Bool
    let signOut: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if let profile = store.profile {
                    Section("Signed in") {
                        HStack(spacing: 14) {
                            ProfileAvatar(name: profile.name, image: store.avatarImage, size: 60)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name).font(.headline)
                                Text("@\(profile.username)").font(.subheadline).foregroundStyle(.secondary)
                                Text(profile.role.capitalized).font(.caption.weight(.semibold))
                                    .foregroundStyle(ServiceOpsTheme.greenText)
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }
                }
                Section("Work and reference") {
                    NavigationLink { DashboardsView(store: store, baseURL: $baseURL, apiToken: $apiToken) } label: { Label("Dashboards", systemImage: "rectangle.3.group") }
                    NavigationLink { ProjectsView(baseURL: baseURL, token: apiToken) } label: { Label("Projects", systemImage: "square.stack.3d.up") }
                    NavigationLink { ApprovalsView(baseURL: baseURL, token: apiToken) } label: { Label("My approvals", systemImage: "checkmark.seal") }
                    NavigationLink { KnowledgeView(baseURL: baseURL, token: apiToken) } label: { Label("Knowledge", systemImage: "book.closed") }
                }
                Section("Infrastructure") {
                    if store.capabilities?.viewCmdb == true {
                        NavigationLink { CMDBView(baseURL: baseURL, token: apiToken) } label: {
                            Label("Servers and assets", systemImage: "server.rack")
                        }
                        Text("Locations, racks, hardware and ownership").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Asset access requires an IT role", systemImage: "lock").foregroundStyle(.secondary)
                    }
                }
                Section("Account and connection") {
                    NavigationLink {
                        ServerInformationView(store: store, baseURL: baseURL)
                    } label: { Label("ServiceOps server", systemImage: "network") }
                    NavigationLink {
                        SettingsView(store: store, baseURL: $baseURL, apiToken: $apiToken,
                                     biometricLockEnabled: $biometricLockEnabled, signOut: signOut)
                    } label: { Label("Settings and security", systemImage: "gearshape") }
                }
                Section("About") {
                    LabeledContent("ServiceOps", value: AppIdentity.displayVersion)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("ServiceOps \(AppIdentity.displayVersion)")
                }
            }
            .navigationTitle("More")
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var store: ServiceOpsStore
    @Binding var baseURL: String
    @Binding var apiToken: String
    @Binding var biometricLockEnabled: Bool
    let signOut: () -> Void
    @State private var isRegisteringPasskey = false
    @State private var securityMessage: String?
    @State private var passkeys: [PasskeyRecord] = []

    var body: some View {
        NavigationStack {
            ZStack {
                ServiceOpsTheme.nowBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        WorkspaceHeader(
                            title: "Settings",
                            subtitle: store.connectionMessage ?? "Account, connection and device security",
                            systemImage: "gearshape",
                            isLoading: store.isCheckingConnection,
                            action: nil
                        )

                        RecordPanel(title: "Connection", subtitle: "ServiceOps API") {
                            VStack(spacing: 14) {
                                FloatingField(title: "Server URL", text: $baseURL, axis: .horizontal)
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.URL)
                                    .autocorrectionDisabled()

                                Label("Signed in with your ServiceOps user account", systemImage: "person.crop.circle.badge.checkmark")

                                Button {
                                    Task { await store.checkConnection(baseURL: baseURL) }
                                } label: {
                                    if store.isCheckingConnection {
                                        ProgressView()
                                            .frame(maxWidth: .infinity)
                                    } else {
                                        Label("Test server", systemImage: "network")
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(store.isCheckingConnection)

                                Button("Sign out", role: .destructive, action: signOut)
                            }
                        }

                        RecordPanel(title: "Security", subtitle: "Device authentication") {
                            VStack(alignment: .leading, spacing: 14) {
                                Toggle(isOn: $biometricLockEnabled) {
                                    Label("Require biometric unlock", systemImage: "faceid")
                                }
                                Text("Locks ServiceOps whenever the app leaves the foreground. Your device passcode remains the recovery method.")
                                    .font(.caption)
                                    .foregroundStyle(ServiceOpsTheme.muted)

                                Button {
                                    Task { await registerPasskey() }
                                } label: {
                                    if isRegisteringPasskey {
                                        ProgressView().frame(maxWidth: .infinity)
                                    } else {
                                        Label("Create passkey", systemImage: "person.badge.key.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(isRegisteringPasskey)

                                if !passkeys.isEmpty {
                                    Divider()
                                    ForEach(passkeys) { passkey in
                                        HStack {
                                            Label(passkey.name, systemImage: "key.fill")
                                            Spacer()
                                            Button(role: .destructive) {
                                                Task { await deletePasskey(passkey) }
                                            } label: {
                                                Image(systemName: "trash")
                                            }
                                            .accessibilityLabel("Delete \(passkey.name)")
                                        }
                                    }
                                }
                            }
                        }

                        RecordPanel(title: "About", subtitle: "Installed application") {
                            LabeledContent("App version", value: AppIdentity.version)
                            Divider()
                            LabeledContent("Build", value: AppIdentity.build)
                        }

                        if let securityMessage {
                            StatusNotice(message: securityMessage, systemImage: "key.fill", color: ServiceOpsTheme.green)
                        }

                        if let message = store.connectionMessage {
                            StatusNotice(message: message, systemImage: "checkmark.seal.fill", color: ServiceOpsTheme.green)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadPasskeys() }
        }
    }

    private func registerPasskey() async {
        isRegisteringPasskey = true
        defer { isRegisteringPasskey = false }
        do {
            let record = try await PasskeyManager().register(baseURL: baseURL, accessToken: apiToken)
            securityMessage = "\(record.name) is ready for passwordless sign-in."
            await loadPasskeys()
        } catch {
            securityMessage = error.localizedDescription
        }
    }

    private func loadPasskeys() async {
        do {
            let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: apiToken)
            passkeys = try await client.listPasskeys()
        } catch {
            securityMessage = error.localizedDescription
        }
    }

    private func deletePasskey(_ passkey: PasskeyRecord) async {
        do {
            let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: apiToken)
            try await client.deletePasskey(id: passkey.id)
            passkeys.removeAll { $0.id == passkey.id }
            securityMessage = "\(passkey.name) was revoked."
        } catch {
            securityMessage = error.localizedDescription
        }
    }
}

struct WorkspaceHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isLoading: Bool
    let action: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(ServiceOpsTheme.green)
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(ServiceOpsTheme.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(ServiceOpsTheme.muted)
            }

            Spacer()

            if let action {
                Button(action: action) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(IconButtonStyle())
                .disabled(isLoading)
                .accessibilityLabel("Refresh")
            }
        }
        .padding(16)
        .background(ServiceOpsTheme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ServiceOpsTheme.line))
        .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }
}

private struct RecordToolbar: View {
    let ticket: ServiceTicket
    let isSaving: Bool
    var canSave = true
    let save: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RecordTypeIcon(kind: ticket.type)
            VStack(alignment: .leading, spacing: 2) {
                Text(ticket.type.rawValue.capitalized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ServiceOpsTheme.ink)
                Text(ticket.number)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(ServiceOpsTheme.muted)
            }
            Spacer()
            Text("Updated \(ServiceOpsDate.format(ticket.updatedAt))")
                .font(.caption2)
                .foregroundStyle(ServiceOpsTheme.muted)
                .lineLimit(1)
            Button(action: save) {
                if isSaving {
                    ProgressView()
                } else {
                    Image(systemName: "checkmark")
                }
            }
            .buttonStyle(IconButtonStyle())
            .disabled(isSaving || !canSave)
            .accessibilityLabel("Save changes")
        }
        .padding(12)
        .background(ServiceOpsTheme.toolbarBackground, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ServiceOpsTheme.line))
    }
}

private struct StateTrack: View {
    let currentState: String
    private let states = ["New", "In Progress", "Resolved", "Closed"]

    private var currentIndex: Int {
        states.firstIndex(of: currentState) ?? 0
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(states.enumerated()), id: \.offset) { index, state in
                Text(state)
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(index <= currentIndex ? .white : ServiceOpsTheme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(index <= currentIndex ? ServiceOpsTheme.green : ServiceOpsTheme.trackInactive, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("State \(currentState)")
    }
}

private struct RecordPanel<Content: View>: View {
    let title: String?
    let subtitle: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(ServiceOpsTheme.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(ServiceOpsTheme.muted)
                    }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ServiceOpsTheme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ServiceOpsTheme.line))
        .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }
}

private struct FactCell: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(ServiceOpsTheme.green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption2.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(ServiceOpsTheme.muted)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ServiceOpsTheme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ServiceOpsTheme.fieldBackground, in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct FloatingField: View {
    let title: String
    @Binding var text: String
    let axis: Axis
    var isSecure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ServiceOpsTheme.muted)
            if isSecure {
                SecureField(title, text: $text)
                    .textFieldStyle(ServiceOpsTextFieldStyle())
            } else {
                TextField(title, text: $text, axis: axis)
                    .lineLimit(axis == .vertical ? 4...8 : 1...1)
                    .textFieldStyle(ServiceOpsTextFieldStyle())
            }
        }
    }
}

private struct StatusNotice: View {
    let message: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ServiceOpsTheme.ink)
            Spacer()
        }
        .padding(14)
        .background(ServiceOpsTheme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ServiceOpsTheme.line))
    }
}

private struct RecordTypeIcon: View {
    let kind: TicketKind

    var body: some View {
        Text(kind == .change ? "C" : "T")
            .font(.headline.weight(.black))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(kind == .change ? ServiceOpsTheme.changeBrown : ServiceOpsTheme.tealDark, in: Circle())
    }
}

struct PriorityBadge: View {
    let priority: String

    var body: some View {
        HStack(spacing: 6) {
            PriorityDot(priority: priority)
            Text(priority)
                .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .foregroundStyle(priorityForeground)
        .background(priorityBackground, in: Capsule())
        .accessibilityLabel("Priority \(priority)")
    }

    private var priorityForeground: Color {
        switch priority {
        case "P1": ServiceOpsTheme.adaptive(light: (0.65, 0.17, 0.13), dark: (1.00, 0.66, 0.62))
        case "P2": ServiceOpsTheme.adaptive(light: (0.61, 0.36, 0.00), dark: (1.00, 0.78, 0.45))
        case "P3": ServiceOpsTheme.adaptive(light: (0.27, 0.38, 0.36), dark: (0.68, 0.82, 0.79))
        default: ServiceOpsTheme.adaptive(light: (0.33, 0.38, 0.42), dark: (0.72, 0.77, 0.81))
        }
    }

    private var priorityBackground: Color {
        switch priority {
        case "P1": ServiceOpsTheme.adaptive(light: (0.99, 0.90, 0.89), dark: (0.36, 0.11, 0.09))
        case "P2": ServiceOpsTheme.adaptive(light: (1.00, 0.94, 0.85), dark: (0.34, 0.22, 0.04))
        case "P3": ServiceOpsTheme.adaptive(light: (0.93, 0.95, 0.95), dark: (0.15, 0.21, 0.20))
        default: ServiceOpsTheme.adaptive(light: (0.91, 0.93, 0.95), dark: (0.17, 0.20, 0.23))
        }
    }
}

struct PriorityDot: View {
    let priority: String

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch priority {
        case "P1": .red
        case "P2": ServiceOpsTheme.amber
        case "P3": Color(red: 0.42, green: 0.62, blue: 0.68)
        default: Color(red: 0.59, green: 0.67, blue: 0.68)
        }
    }
}

struct StateBadge: View {
    let state: String

    var body: some View {
        Text(state)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(ServiceOpsTheme.muted)
            .background(ServiceOpsTheme.badgeBackground, in: Capsule())
    }
}

private struct ServiceOpsTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.subheadline)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(ServiceOpsTheme.surface, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(ServiceOpsTheme.fieldBorder))
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(configuration.isPressed ? ServiceOpsTheme.greenDark : ServiceOpsTheme.green, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(ServiceOpsTheme.ink)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(configuration.isPressed ? ServiceOpsTheme.fieldBackground : ServiceOpsTheme.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(ServiceOpsTheme.line))
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(ServiceOpsTheme.ink)
            .frame(width: 34, height: 34)
            .background(configuration.isPressed ? ServiceOpsTheme.fieldBackground : ServiceOpsTheme.surface, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(ServiceOpsTheme.line))
    }
}

private extension View {
    func serviceOpsAlert(store: ServiceOpsStore) -> some View {
        alert("ServiceOps", isPresented: Binding(
            get: { store.errorMessage != nil },
            // Clearing on the next turn keeps the store from publishing during the
            // view update that dismisses the alert.
            set: { isPresented in
                if !isPresented { Task { @MainActor in store.errorMessage = nil } }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

/// App palette. Neutral and text colors adapt to light and dark appearance; brand fills
/// (header gradient, record-type circles, primary buttons) stay the same in both so white
/// text on them keeps its contrast.
enum ServiceOpsTheme {
    static let nav = Color(red: 0.06, green: 0.10, blue: 0.14)
    static let ink = adaptive(light: (0.09, 0.13, 0.17), dark: (0.91, 0.94, 0.95))
    static let muted = adaptive(light: (0.40, 0.46, 0.51), dark: (0.62, 0.68, 0.72))
    static let line = adaptive(light: (0.87, 0.90, 0.91), dark: (0.22, 0.26, 0.29))
    static let background = adaptive(light: (0.96, 0.97, 0.97), dark: (0.04, 0.06, 0.07))
    static let nowBackground = adaptive(light: (0.95, 0.97, 0.98), dark: (0.04, 0.06, 0.07))
    static let nowLine = adaptive(light: (0.88, 0.91, 0.93), dark: (0.20, 0.24, 0.27))
    static let toolbarBackground = adaptive(light: (0.97, 0.98, 0.98), dark: (0.09, 0.11, 0.13))
    static let headerBackground = adaptive(light: (0.93, 0.95, 0.96), dark: (0.12, 0.15, 0.17))
    static let fieldBackground = adaptive(light: (0.95, 0.97, 0.97), dark: (0.14, 0.17, 0.19))
    static let badgeBackground = adaptive(light: (0.93, 0.95, 0.95), dark: (0.17, 0.20, 0.23))
    /// Cards and panels: white in light mode, a raised dark gray in dark mode.
    static let surface = adaptive(light: (1.00, 1.00, 1.00), dark: (0.10, 0.13, 0.15))
    static let fieldBorder = adaptive(light: (0.78, 0.82, 0.84), dark: (0.30, 0.35, 0.38))
    static let trackInactive = adaptive(light: (0.89, 0.92, 0.93), dark: (0.20, 0.24, 0.27))
    static let green = Color(red: 0.09, green: 0.63, blue: 0.52)
    static let greenDark = Color(red: 0.05, green: 0.49, blue: 0.41)
    static let nowGreen = Color(red: 0.00, green: 0.57, blue: 0.42)
    static let nowGreenDark = Color(red: 0.00, green: 0.31, blue: 0.28)
    static let tealDark = Color(red: 0.00, green: 0.24, blue: 0.30)
    /// Text and icon variants of the dark brand colors, readable on `surface` in dark mode.
    static let greenText = adaptive(light: (0.00, 0.31, 0.28), dark: (0.36, 0.84, 0.70))
    static let tealText = adaptive(light: (0.00, 0.24, 0.30), dark: (0.45, 0.80, 0.86))
    static let amber = Color(red: 0.98, green: 0.67, blue: 0.24)
    static let blue = Color(red: 0.15, green: 0.45, blue: 0.78)
    static let purple = Color(red: 0.42, green: 0.30, blue: 0.78)
    static let changeBrown = Color(red: 0.44, green: 0.36, blue: 0.09)

    static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}

enum ServiceOpsDate {
    static func date(from value: String) -> Date? {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]
        return isoFormatter.date(from: value) ?? fallbackFormatter.date(from: value)
    }

    static func format(_ value: String) -> String {
        guard let date = date(from: value) else { return value }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
