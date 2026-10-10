import QuickLook
import SwiftUI

struct NotificationInboxView: View {
    let baseURL: String
    let token: String
    @State private var rows: [MobileNotification] = []
    @State private var errorMessage: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            Group {
                if loading && rows.isEmpty { ProgressView("Loading notifications") }
                else if rows.isEmpty { ContentUnavailableView("No notifications", systemImage: "bell.slash") }
                else {
                    List(rows) { row in
                        Button { Task { await markRead(row) } } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Circle().fill(row.read ? .clear : .blue).frame(width: 8, height: 8).padding(.top, 7)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.title).font(.headline).foregroundStyle(.primary)
                                    Text(row.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                    Text(ServiceOpsDate.format(row.createdAt)).font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }.buttonStyle(.plain)
                    }.listStyle(.plain)
                }
            }
            .navigationTitle("Notifications")
            .toolbar { Button("Read all") { Task { await markAllRead() } }.disabled(rows.allSatisfy(\.read)) }
            .refreshable { await load() }
            .task { await load() }
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
    private func markRead(_ row: MobileNotification) async {
        do { try await ServiceOpsAPIClient(baseURLString: baseURL, token: token).markNotificationRead(id: row.id); await load() }
        catch { errorMessage = error.localizedDescription }
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
