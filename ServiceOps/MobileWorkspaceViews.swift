import QuickLook
import SwiftUI

/// Where tapping a notification leads, from the server's `target_type`/`target_id`.
private enum NotificationRoute: Hashable {
    case ticket(ServiceTicket)
    case approvals

    /// Target types the app has a screen for; others (client tickets, RITMs, contracts,
    /// enterprise records) are only marked read.
    static func isSupported(_ targetType: String?, targetID: Int?) -> Bool {
        switch targetType {
        case "ticket": targetID != nil
        case "approval_queue": true
        default: false
        }
    }
}

struct NotificationInboxView<TicketDestination: View>: View {
    let baseURL: String
    let token: String
    @ViewBuilder let ticketDestination: (ServiceTicket) -> TicketDestination
    @ObservedObject private var push = PushNotificationCoordinator.shared
    @State private var rows: [MobileNotification] = []
    @State private var errorMessage: String?
    @State private var loading = false
    @State private var route: NotificationRoute?
    @State private var openingID: Int?

    var body: some View {
        NavigationStack {
            Group {
                if loading && rows.isEmpty { ProgressView("Loading notifications") }
                else if rows.isEmpty { ContentUnavailableView("No notifications", systemImage: "bell.slash") }
                else {
                    List(rows) { row in
                        Button {
                            Task { await open(notificationID: row.id, targetType: row.targetType, targetID: row.targetId) }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Circle().fill(row.read ? .clear : .blue).frame(width: 8, height: 8).padding(.top, 7)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.title).font(.headline).foregroundStyle(.primary)
                                    Text(row.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                    Text(ServiceOpsDate.format(row.createdAt)).font(.caption).foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                                if openingID == row.id {
                                    ProgressView().padding(.top, 4)
                                } else if NotificationRoute.isSupported(row.targetType, targetID: row.targetId) {
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 6)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(openingID != nil)
                    }.listStyle(.plain)
                }
            }
            .navigationTitle("Notifications")
            .navigationDestination(item: $route) { route in
                switch route {
                case .ticket(let ticket): ticketDestination(ticket)
                case .approvals: ApprovalsView(baseURL: baseURL, token: token)
                }
            }
            .toolbar { Button("Read all") { Task { await markAllRead() } }.disabled(rows.allSatisfy(\.read)) }
            .refreshable { await load() }
            .task { await load() }
            // A tapped push notification opens its target here, including one tapped before launch.
            .onChange(of: push.pendingTarget, initial: true) { _, target in
                guard let target else { return }
                push.pendingTarget = nil
                Task { await open(notificationID: target.notificationID, targetType: target.targetType, targetID: target.targetID) }
            }
            .alert("ServiceOps", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            rows = try await ServiceOpsAPIClient(baseURLString: baseURL, token: token).notifications()
            PushNotificationCoordinator.shared.unreadCount = rows.filter { !$0.read }.count
        } catch { errorMessage = error.localizedDescription }
    }

    /// Marks the notification read, then navigates to what it was about.
    private func open(notificationID: Int?, targetType: String?, targetID: Int?) async {
        openingID = notificationID
        defer { openingID = nil }
        do {
            let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: token)
            if let notificationID {
                // Navigation shouldn't depend on the read receipt succeeding.
                try? await client.markNotificationRead(id: notificationID)
            }
            switch targetType {
            case "ticket":
                guard let targetID else { break }
                if let ticket = try await client.ticket(id: targetID) {
                    route = .ticket(ticket)
                } else {
                    errorMessage = "This ticket is no longer available to your account."
                }
            case "approval_queue":
                route = .approvals
            default:
                break
            }
        } catch {
            errorMessage = (error as? ServiceOpsAPIError)?.serverMessage ?? error.localizedDescription
        }
        await load()
    }
    private func markAllRead() async {
        do { try await ServiceOpsAPIClient(baseURLString: baseURL, token: token).markAllNotificationsRead(); await load() }
        catch { errorMessage = error.localizedDescription }
    }
}

struct ApprovalsView: View {
    let baseURL: String; let token: String
    @State private var rows: [MobileApproval] = []
    @State private var errorMessage: String?
    var body: some View {
        List(rows) { row in
            VStack(alignment: .leading, spacing: 8) {
                Text(row.chain).font(.headline)
                Text(row.gate).foregroundStyle(.secondary)
                Text(row.state).font(.caption.bold()).foregroundStyle(row.state == "Requested" ? .orange : .secondary)
                if row.state == "Requested" {
                    HStack {
                        Button("Approve") { Task { await decide(row, "Approved") } }.buttonStyle(.borderedProminent)
                        Button("Reject", role: .destructive) { Task { await decide(row, "Rejected") } }.buttonStyle(.bordered)
                    }
                }
            }.padding(.vertical, 5)
        }
        .navigationTitle("My approvals")
        .refreshable { await load() }.task { await load() }
        .overlay { if rows.isEmpty { ContentUnavailableView("No approvals", systemImage: "checkmark.seal") } }
        .alert("ServiceOps", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }
    private func load() async { do { rows = try await ServiceOpsAPIClient(baseURLString: baseURL, token: token).approvals() } catch { errorMessage = error.localizedDescription } }
    private func decide(_ row: MobileApproval, _ decision: String) async { do { try await ServiceOpsAPIClient(baseURLString: baseURL, token: token).decideApproval(id: row.id, decision: decision, comments: "Decided in ServiceOps iOS"); await load() } catch { errorMessage = error.localizedDescription } }
}

struct KnowledgeView: View {
    let baseURL: String; let token: String
    @State private var rows: [KnowledgeArticle] = []; @State private var query = ""
    var body: some View {
        List(rows) { row in NavigationLink { ScrollView { Text(row.body).frame(maxWidth: .infinity, alignment: .leading).padding() }.navigationTitle(row.title) } label: { VStack(alignment: .leading) { Text(row.title).font(.headline); Text(row.category).font(.caption).foregroundStyle(.secondary) } } }
            .navigationTitle("Knowledge").searchable(text: $query).task(id: query) { try? await Task.sleep(for: .milliseconds(250)); rows = (try? await ServiceOpsAPIClient(baseURLString: baseURL, token: token).knowledge(query: query)) ?? [] }
    }
}


struct TicketCommentsView: View {
    let number: String; let baseURL: String; let token: String
    @State private var rows: [TicketComment] = []; @State private var commentText = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity").font(.headline)
            ForEach(rows) { row in VStack(alignment: .leading, spacing: 3) { Text(row.author).font(.subheadline.bold()); Text(row.body); Text(ServiceOpsDate.format(row.createdAt)).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding().background(ServiceOpsTheme.surface, in: RoundedRectangle(cornerRadius: 12)) }
            HStack { TextField("Add a work note", text: $commentText, axis: .vertical).textFieldStyle(.roundedBorder); Button { Task { await add() } } label: { Image(systemName: "paperplane.fill") }.disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.task { await load() }
    }
    private func load() async { rows = (try? await ServiceOpsAPIClient(baseURLString: baseURL, token: token).comments(number: number)) ?? [] }
    private func add() async { let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }; if (try? await ServiceOpsAPIClient(baseURLString: baseURL, token: token).addComment(number: number, body: text)) != nil { commentText = ""; await load() } }
}

struct TicketAttachmentsView: View {
    let number: String; let baseURL: String; let token: String
    @State private var rows: [TicketAttachment] = []
    @State private var downloadingID: Int?
    @State private var previewURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Attachments").font(.headline)
            if rows.isEmpty {
                Text("No attachments").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                Button { Task { await open(row) } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: Self.icon(for: row.contentType)).font(.title3).frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.fileName).font(.subheadline.bold()).foregroundStyle(.primary).lineLimit(2)
                            Text("\(row.byteSize.formatted(.byteCount(style: .file))) · \(ServiceOpsDate.format(row.createdAt))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if downloadingID == row.id { ProgressView() } else { Image(systemName: "eye").foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
                    .background(ServiceOpsTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(downloadingID != nil)
                .accessibilityHint("Opens a preview")
            }
        }
        .task { await load() }
        .quickLookPreview($previewURL)
        .alert("ServiceOps", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    private func load() async {
        do { rows = try await ServiceOpsAPIClient(baseURLString: baseURL, token: token).attachments(number: number) }
        catch { errorMessage = error.localizedDescription }
    }

    private func open(_ row: TicketAttachment) async {
        downloadingID = row.id; defer { downloadingID = nil }
        do { previewURL = try await ServiceOpsAPIClient(baseURLString: baseURL, token: token).downloadAttachment(number: number, attachment: row) }
        catch { errorMessage = error.localizedDescription }
    }

    private static func icon(for contentType: String) -> String {
        if contentType.hasPrefix("image/") { return "photo" }
        if contentType == "application/pdf" { return "doc.richtext" }
        if contentType.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }
}

struct ChangeTasksView: View {
    let number: String; let baseURL: String; let token: String; let canManage: Bool
    @State private var rows: [ChangeTask] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change tasks").font(.headline)
            if rows.isEmpty {
                Text("No change tasks").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                NavigationLink {
                    ChangeTaskDetailView(number: number, baseURL: baseURL, token: token, canManage: canManage, task: row) { updated in
                        if let index = rows.firstIndex(where: { $0.id == updated.id }) { rows[index] = updated }
                    }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(row.sequence)").font(.caption.bold().monospacedDigit()).frame(width: 22, height: 22)
                            .background(.quaternary, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title).font(.subheadline.bold()).foregroundStyle(.primary)
                            Text([row.number, row.state, row.assignee ?? row.assignmentGroup].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
                    .background(ServiceOpsTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .task { await load() }
        .alert("ServiceOps", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    private func load() async {
        do { rows = try await ServiceOpsAPIClient(baseURLString: baseURL, token: token).changeTasks(number: number) }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct ChangeTaskDetailView: View {
    let number: String; let baseURL: String; let token: String; let canManage: Bool
    @State var task: ChangeTask
    let onUpdate: (ChangeTask) -> Void
    @State private var selectedState = ""
    @State private var note = ""
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Task") {
                LabeledContent("Number", value: task.number)
                LabeledContent("Type", value: task.taskType)
                LabeledContent("Required", value: task.required ? "Yes" : "No")
                if let group = task.assignmentGroup { LabeledContent("Assignment group", value: group) }
                if let assignee = task.assignee { LabeledContent("Assigned to", value: assignee) }
                if let start = task.plannedStart { LabeledContent("Planned start", value: ServiceOpsDate.format(start)) }
                if let end = task.plannedEnd { LabeledContent("Planned end", value: ServiceOpsDate.format(end)) }
            }
            if canManage {
                Section("Update") {
                    Picker("State", selection: $selectedState) {
                        ForEach(task.stateOptions, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Append a work note", text: $note, axis: .vertical)
                    Button { Task { await save() } } label: {
                        if saving { ProgressView() } else { Text("Save changes") }
                    }
                    .disabled(saving || !hasChanges)
                }
            }
            Section("Work notes") {
                Text(task.workNotes.isEmpty ? "No work notes" : task.workNotes)
                    .font(.callout).foregroundStyle(task.workNotes.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(task.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if selectedState.isEmpty { selectedState = task.state } }
        .alert("ServiceOps", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    private var trimmedNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasChanges: Bool { selectedState != task.state || !trimmedNote.isEmpty }

    private func save() async {
        saving = true; defer { saving = false }
        do {
            let updated = try await ServiceOpsAPIClient(baseURLString: baseURL, token: token).updateChangeTask(
                number: number, task: task.number,
                state: selectedState == task.state ? nil : selectedState,
                note: trimmedNote.isEmpty ? nil : trimmedNote
            )
            task = updated
            selectedState = updated.state
            note = ""
            onUpdate(updated)
        } catch { errorMessage = error.localizedDescription }
    }
}

/// Read-only sections come from the same ticket relationships used by the Web UI.
struct TicketInformationView: View {
    let details: TicketDetails
    let baseURL: String
    let token: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Configuration items and services").font(.headline)
                if details.configurationItems.isEmpty {
                    Text("No linked configuration items are available to your account.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(details.configurationItems, id: \.relationshipID) { item in
                    ConfigurationItemRow(item: item, baseURL: baseURL, token: token)
                }
            }
            .padding().background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))

            ForEach(details.sections) { section in
                DisclosureGroup {
                    if section.entries.isEmpty {
                        Text("No records").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(section.entries) { entry in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(entry.title).font(.subheadline.weight(.semibold))
                            ForEach(Array(entry.fields.enumerated()), id: \.offset) { _, field in
                                detailField(field.label, value: field.value)
                            }
                        }.padding(.vertical, 8)
                        if entry.id != section.entries.last?.id { Divider() }
                    }
                } label: {
                    HStack {
                        Text(section.title).font(.headline)
                        Spacer()
                        Text(String(section.entries.count)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding().background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func detailField(_ label: String, value: String?) -> some View {
        CIDetailField(label: label, value: value)
    }
}

private struct CIDetailField: View {
    let label: String
    let value: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "Not recorded")
                .font(.subheadline).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One linked CI. A rack-mounted CI shows a location link under its name that opens the
/// full rack view with the device highlighted. The row is custom rather than a DisclosureGroup
/// so the link isn't nested inside the disclosure toggle button.
private struct ConfigurationItemRow: View {
    let item: TicketConfigurationItem
    let baseURL: String
    let token: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(item.relationshipRole).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if let rack = item.rack, let rackID = rack.id {
                NavigationLink {
                    ServerRackView(rackID: rackID, selectedAssetID: item.id, baseURL: baseURL, token: token)
                } label: {
                    Label(locationSummary(rack), systemImage: "mappin.and.ellipse")
                        .font(.caption.weight(.medium))
                }
                .accessibilityHint("Opens the rack view with this device highlighted")
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    CIDetailField(label: "Class", value: item.ciClass)
                    CIDetailField(label: "Environment", value: item.environment)
                    CIDetailField(label: "Status", value: item.status)
                    CIDetailField(label: "IP address", value: item.ipAddress)
                    CIDetailField(label: "Location", value: item.location)
                    CIDetailField(label: "Serial number", value: item.serialNumber)
                    CIDetailField(label: "Vendor", value: item.vendor)
                    CIDetailField(label: "Model", value: item.model)
                    CIDetailField(label: "Description", value: item.description)
                    if let rack = item.rack {
                        CIDetailField(label: "Site", value: rack.site)
                        CIDetailField(label: "Rack", value: rack.name)
                        CIDetailField(label: "Position", value: rack.position.map { String(format: "U%g", $0) })
                        CIDetailField(label: "Height", value: rack.uHeight.map { "\($0) U" })
                        CIDetailField(label: "Face", value: rack.face?.capitalized)
                    }
                }.padding(.top, 8)
            }
        }
    }

    /// e.g. "Rack A12 · U8.5"
    private func locationSummary(_ rack: AssetRackLocation) -> String {
        [rack.name, rack.position.map { String(format: "U%g", $0) }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
