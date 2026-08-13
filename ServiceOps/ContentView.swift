import SwiftUI

struct ContentView: View {
    @StateObject private var store = ServiceOpsStore()
    @AppStorage("serviceops.baseURL") private var baseURL = "http://127.0.0.1"
    @State private var apiToken = SecureSessionStore.read(account: "accessToken") ?? ""
    @State private var selectedTab: AppTab = .home

    @ViewBuilder
    var body: some View {
        if apiToken.isEmpty {
            MobileLoginView(baseURL: $baseURL) { response in
                try? SecureSessionStore.save(response.accessToken, account: "accessToken")
                try? SecureSessionStore.save(response.refreshToken, account: "refreshToken")
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

            SettingsView(store: store, baseURL: $baseURL, apiToken: $apiToken) {
                Task {
                    if let access = SecureSessionStore.read(account: "accessToken"),
                       let client = try? ServiceOpsAPIClient(baseURLString: baseURL, token: access) {
                        try? await client.logout()
                    }
                    SecureSessionStore.clear()
                    apiToken = ""
                    store.tickets = []
                }
            }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
            }
            .tint(ServiceOpsTheme.nowGreen)
        }
    }
}

private struct MobileLoginView: View {
    @Binding var baseURL: String
    let authenticated: (MobileAuthResponse) -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var mfaCode = ""
    @State private var provider = "local"
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("ServiceOps server") {
                    TextField("Server URL", text: $baseURL).textInputAutocapitalization(.never).keyboardType(.URL)
                }
                Section("Sign in") {
                    TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    TextField("MFA or backup code (if enabled)", text: $mfaCode).keyboardType(.numberPad)
                    Picker("Authentication", selection: $provider) {
                        Text("Local account").tag("local")
                        Text("Directory / LDAP").tag("ldap")
                    }
                    Button(isSigningIn ? "Signing in…" : "Sign in") { Task { await signIn() } }
                        .disabled(isSigningIn || username.isEmpty || password.isEmpty)
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle("ServiceOps")
        }
    }

    private func signIn() async {
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: "")
            let response = try await client.login(username: username, password: password, provider: provider,
                                                  mfaCode: mfaCode.isEmpty ? nil : mfaCode)
            authenticated(response)
        } catch { errorMessage = error.localizedDescription }
    }
}

private enum AppTab: Hashable {
    case home
    case work
    case create
    case settings
}

private struct HomeView: View {
    @ObservedObject var store: ServiceOpsStore
    @Binding var baseURL: String
    @Binding var apiToken: String
    @Binding var selectedTab: AppTab

    private var activeTickets: [ServiceTicket] {
        store.tickets.filter { !["Closed", "Cancelled"].contains($0.state) }
    }

    private var majorCandidates: [ServiceTicket] {
        store.tickets.filter { $0.type == .incident && $0.priority == "P1" }
    }

    private var recentTickets: [ServiceTicket] {
        Array(store.tickets.prefix(4))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ServiceOpsTheme.nowBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        MobileHomeHeader(
                            totalCount: store.tickets.count,
                            activeCount: activeTickets.count,
                            isLoading: store.isLoadingTickets
                        ) {
                            Task { await store.loadTickets(baseURL: baseURL, token: apiToken, filter: .all) }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("Applications")
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                                AppletCard(
                                    title: "My Work",
                                    subtitle: "Tasks assigned to you",
                                    value: "\(activeTickets.count)",
                                    icon: "checklist",
                                    color: ServiceOpsTheme.nowGreen
                                ) {
                                    selectedTab = .work
                                }

                                AppletCard(
                                    title: "My Group's Work",
                                    subtitle: "Open group records",
                                    value: "\(activeTickets.count)",
                                    icon: "person.3.fill",
                                    color: ServiceOpsTheme.blue
                                ) {
                                    selectedTab = .work
                                }

                                AppletCard(
                                    title: "Major Incidents",
                                    subtitle: "Critical incidents",
                                    value: "\(majorCandidates.count)",
                                    icon: "exclamationmark.triangle.fill",
                                    color: .red
                                ) {
                                    selectedTab = .work
                                }

                                AppletCard(
                                    title: "My Approvals",
                                    subtitle: "Pending decisions",
                                    value: "0",
                                    icon: "hand.thumbsup.fill",
                                    color: ServiceOpsTheme.purple,
                                    isEnabled: false
                                ) {}
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("Quick actions")
                            HStack(spacing: 12) {
                                QuickActionButton(title: "Report issue", icon: "plus.message.fill") {
                                    selectedTab = .create
                                }
                                QuickActionButton(title: "Scan asset", icon: "barcode.viewfinder") {}
                                QuickActionButton(title: "Knowledge", icon: "book.closed.fill") {}
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                SectionLabel("Recent")
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
                                        NavigationLink {
                                            TicketDetailView(ticket: ticket, store: store, baseURL: $baseURL, apiToken: $apiToken)
                                        } label: {
                                            MobileRecordCard(ticket: ticket)
                                        }
                                        .buttonStyle(.plain)
                                        if ticket.id != recentTickets.last?.id {
                                            Divider().padding(.leading, 68)
                                        }
                                    }
                                }
                            }
                            .background(.white, in: RoundedRectangle(cornerRadius: 16))
                            .shadow(color: .black.opacity(0.06), radius: 16, y: 8)
                        }
                    }
                    .padding(18)
                }
                .refreshable {
                    await store.loadTickets(baseURL: baseURL, token: apiToken, filter: .all)
                }
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if store.tickets.isEmpty {
                    await store.loadTickets(baseURL: baseURL, token: apiToken, filter: .all)
                }
            }
            .serviceOpsAlert(store: store)
        }
    }
}

private struct TicketsView: View {
    @ObservedObject var store: ServiceOpsStore
    @Binding var baseURL: String
    @Binding var apiToken: String
    @State private var filter: TicketTypeFilter = .all
    @State private var searchText = ""

    private var visibleTickets: [ServiceTicket] {
        guard !searchText.isEmpty else { return store.tickets }
        return store.tickets.filter { ticket in
            ticket.number.localizedCaseInsensitiveContains(searchText)
            || ticket.title.localizedCaseInsensitiveContains(searchText)
            || ticket.state.localizedCaseInsensitiveContains(searchText)
            || ticket.priority.localizedCaseInsensitiveContains(searchText)
            || ticket.assignmentGroupName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var openCount: Int {
        store.tickets.filter { !["Closed", "Cancelled"].contains($0.state) }.count
    }

    private var criticalCount: Int {
        store.tickets.filter { ["P1", "P2"].contains($0.priority) }.count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ServiceOpsTheme.nowBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        WorkspaceHeader(
                            title: "My work",
                            subtitle: "\(store.tickets.count) records",
                            systemImage: "rectangle.grid.1x2",
                            isLoading: store.isLoadingTickets
                        ) {
                            Task { await store.loadTickets(baseURL: baseURL, token: apiToken, filter: filter) }
                        }

                        SummaryStrip(items: [
                            SummaryItem(title: "Open", value: String(openCount), color: ServiceOpsTheme.green, icon: "tray.full"),
                            SummaryItem(title: "High risk", value: String(criticalCount), color: .red, icon: "exclamationmark.triangle"),
                            SummaryItem(title: "Groups", value: String(Set(store.tickets.map(\.assignmentGroupName)).count), color: ServiceOpsTheme.amber, icon: "person.3")
                        ])

                        Picker("Type", selection: $filter) {
                            ForEach(TicketTypeFilter.allCases) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)

                        TicketListPanel(tickets: visibleTickets, apiToken: apiToken, isLoading: store.isLoadingTickets) { ticket in
                            TicketDetailView(ticket: ticket, store: store, baseURL: $baseURL, apiToken: $apiToken)
                        }
                    }
                    .padding(16)
                }
                .refreshable {
                    await store.loadTickets(baseURL: baseURL, token: apiToken, filter: filter)
                }
            }
            .navigationTitle("ServiceOps")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Number or short description")
            .task {
                if store.tickets.isEmpty {
                    await store.loadTickets(baseURL: baseURL, token: apiToken, filter: filter)
                }
            }
            .onChange(of: filter) { _, newFilter in
                Task { await store.loadTickets(baseURL: baseURL, token: apiToken, filter: newFilter) }
            }
            .serviceOpsAlert(store: store)
        }
    }
}

private struct TicketListPanel<Destination: View>: View {
    let tickets: [ServiceTicket]
    let apiToken: String
    let isLoading: Bool
    let destination: (ServiceTicket) -> Destination

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .frame(width: 34, height: 34)
                    .background(.white, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(ServiceOpsTheme.line))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tickets")
                        .font(.headline)
                        .foregroundStyle(ServiceOpsTheme.tealDark)
                    Text("All visible incidents and changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isLoading {
                    ProgressView()
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
        .background(.white, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ServiceOpsTheme.line))
        .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }
}

private struct MobileHomeHeader: View {
    let totalCount: Int
    let activeCount: Int
    let isLoading: Bool
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.18))
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text("ServiceOps")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                    Text("Mobile agent workspace")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.78))
                }

                Spacer()

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

            HStack(spacing: 12) {
                HeaderMetric(title: "Records", value: "\(totalCount)")
                HeaderMetric(title: "Active", value: "\(activeCount)")
                HeaderMetric(title: "Online", value: "API")
            }
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

private struct HeaderMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline.weight(.bold))
                .monospacedDigit()
            Text(title)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .opacity(0.72)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
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

private struct AppletCard: View {
    let title: String
    let subtitle: String
    let value: String
    let icon: String
    let color: Color
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: icon)
                        .font(.headline)
                        .foregroundStyle(color)
                        .frame(width: 38, height: 38)
                        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    Spacer()
                    Text(value)
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(ServiceOpsTheme.ink)
                }

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
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 136, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(ServiceOpsTheme.nowLine))
            .opacity(isEnabled ? 1 : 0.58)
            .shadow(color: .black.opacity(0.05), radius: 14, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct QuickActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(ServiceOpsTheme.nowLine))
        }
        .buttonStyle(.plain)
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
                        .foregroundStyle(ServiceOpsTheme.nowGreenDark)
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

private struct TableHeaderRow: View {
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

private struct TicketRow: View {
    let ticket: ServiceTicket

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(ticket.number)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(ServiceOpsTheme.tealDark)
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

private struct TicketDetailView: View {
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

    var body: some View {
        ZStack {
            ServiceOpsTheme.nowBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    RecordToolbar(ticket: displayedTicket, isSaving: store.isSaving) {
                        Task { await saveChanges() }
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
                                FactCell(label: "Category", value: displayedTicket.category, icon: "tag")
                                FactCell(label: "Assignment group", value: displayedTicket.assignmentGroupName, icon: "person.3")
                                FactCell(label: "Assigned to", value: displayedTicket.assigneeName, icon: "person.crop.circle")
                                FactCell(label: "Opened", value: ServiceOpsDate.format(displayedTicket.openedAt), icon: "calendar")
                                FactCell(label: "Updated", value: ServiceOpsDate.format(displayedTicket.updatedAt), icon: "clock")
                            }
                        }
                    }

                    RecordPanel(title: "Update record", subtitle: "State and priority") {
                        VStack(spacing: 14) {
                            Picker("State", selection: $selectedState) {
                                ForEach(TicketState.allCases) { state in
                                    Text(state.rawValue).tag(state.rawValue)
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
                            .disabled(store.isSaving)
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(displayedTicket.number)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.refreshTicket(ticket, baseURL: baseURL, token: apiToken)
        }
        .onChange(of: store.selectedTicket) { _, updatedTicket in
            guard updatedTicket?.id == ticket.id else { return }
            selectedState = updatedTicket?.state ?? selectedState
            selectedPriority = updatedTicket?.priority ?? selectedPriority
        }
        .serviceOpsAlert(store: store)
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
            .serviceOpsAlert(store: store)
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

private struct SettingsView: View {
    @ObservedObject var store: ServiceOpsStore
    @Binding var baseURL: String
    @Binding var apiToken: String
    let signOut: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                ServiceOpsTheme.nowBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        WorkspaceHeader(
                            title: "Settings",
                            subtitle: store.connectionMessage ?? "Local Docker connection",
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

                        if let message = store.connectionMessage {
                            StatusNotice(message: message, systemImage: "checkmark.seal.fill", color: ServiceOpsTheme.green)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .serviceOpsAlert(store: store)
        }
    }
}

private struct WorkspaceHeader: View {
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
        .background(.white, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ServiceOpsTheme.line))
        .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }
}

private struct SummaryStrip: View {
    let items: [SummaryItem]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: item.icon)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(item.color)
                        Spacer()
                    }
                    Text(item.value)
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(ServiceOpsTheme.ink)
                    Text(item.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ServiceOpsTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(item.color)
                        .frame(height: 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(ServiceOpsTheme.line))
            }
        }
    }
}

private struct SummaryItem: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let color: Color
    let icon: String
}

private struct RecordToolbar: View {
    let ticket: ServiceTicket
    let isSaving: Bool
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
            .disabled(isSaving)
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
                    .background(index <= currentIndex ? ServiceOpsTheme.green : Color(red: 0.89, green: 0.92, blue: 0.93), in: RoundedRectangle(cornerRadius: 4))
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
        .background(.white, in: RoundedRectangle(cornerRadius: 6))
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
        .background(.white, in: RoundedRectangle(cornerRadius: 6))
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

private struct PriorityBadge: View {
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
        case "P1": Color(red: 0.65, green: 0.17, blue: 0.13)
        case "P2": Color(red: 0.61, green: 0.36, blue: 0.00)
        case "P3": Color(red: 0.27, green: 0.38, blue: 0.36)
        default: Color(red: 0.33, green: 0.38, blue: 0.42)
        }
    }

    private var priorityBackground: Color {
        switch priority {
        case "P1": Color(red: 0.99, green: 0.90, blue: 0.89)
        case "P2": Color(red: 1.00, green: 0.94, blue: 0.85)
        case "P3": Color(red: 0.93, green: 0.95, blue: 0.95)
        default: Color(red: 0.91, green: 0.93, blue: 0.95)
        }
    }
}

private struct PriorityDot: View {
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

private struct StateBadge: View {
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
            .background(.white, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(red: 0.78, green: 0.82, blue: 0.84)))
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
            .background(configuration.isPressed ? ServiceOpsTheme.fieldBackground : .white, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(ServiceOpsTheme.line))
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(ServiceOpsTheme.ink)
            .frame(width: 34, height: 34)
            .background(configuration.isPressed ? ServiceOpsTheme.fieldBackground : .white, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(ServiceOpsTheme.line))
    }
}

private extension View {
    func serviceOpsAlert(store: ServiceOpsStore) -> some View {
        alert("ServiceOps", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

private enum ServiceOpsTheme {
    static let nav = Color(red: 0.06, green: 0.10, blue: 0.14)
    static let ink = Color(red: 0.09, green: 0.13, blue: 0.17)
    static let muted = Color(red: 0.40, green: 0.46, blue: 0.51)
    static let line = Color(red: 0.87, green: 0.90, blue: 0.91)
    static let background = Color(red: 0.96, green: 0.97, blue: 0.97)
    static let nowBackground = Color(red: 0.95, green: 0.97, blue: 0.98)
    static let nowLine = Color(red: 0.88, green: 0.91, blue: 0.93)
    static let toolbarBackground = Color(red: 0.97, green: 0.98, blue: 0.98)
    static let headerBackground = Color(red: 0.93, green: 0.95, blue: 0.96)
    static let fieldBackground = Color(red: 0.95, green: 0.97, blue: 0.97)
    static let badgeBackground = Color(red: 0.93, green: 0.95, blue: 0.95)
    static let green = Color(red: 0.09, green: 0.63, blue: 0.52)
    static let greenDark = Color(red: 0.05, green: 0.49, blue: 0.41)
    static let nowGreen = Color(red: 0.00, green: 0.57, blue: 0.42)
    static let nowGreenDark = Color(red: 0.00, green: 0.31, blue: 0.28)
    static let tealDark = Color(red: 0.00, green: 0.24, blue: 0.30)
    static let amber = Color(red: 0.98, green: 0.67, blue: 0.24)
    static let blue = Color(red: 0.15, green: 0.45, blue: 0.78)
    static let purple = Color(red: 0.42, green: 0.30, blue: 0.78)
    static let changeBrown = Color(red: 0.44, green: 0.36, blue: 0.09)
}

private enum ServiceOpsDate {
    static func format(_ value: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        let date = isoFormatter.date(from: value) ?? fallbackFormatter.date(from: value)
        guard let date else { return value }

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
