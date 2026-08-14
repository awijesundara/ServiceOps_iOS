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

struct CMDBView: View {
    let baseURL: String; let token: String
    @State private var rows: [ConfigurationItemSummary] = []; @State private var query = ""
    var body: some View {
        List(rows) { row in VStack(alignment: .leading, spacing: 4) { Text(row.name).font(.headline); Text("\(row.ciClass) · \(row.environment) · \(row.status)").font(.caption).foregroundStyle(.secondary); if let ip = row.ipAddress { Text(ip).font(.caption.monospaced()) } } }
            .navigationTitle("CMDB").searchable(text: $query, prompt: "Name, IP, or serial").task(id: query) { try? await Task.sleep(for: .milliseconds(250)); rows = (try? await ServiceOpsAPIClient(baseURLString: baseURL, token: token).configurationItems(query: query)) ?? [] }
    }
}

struct TicketCommentsView: View {
    let number: String; let baseURL: String; let token: String
    @State private var rows: [TicketComment] = []; @State private var commentText = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity").font(.headline)
            ForEach(rows) { row in VStack(alignment: .leading, spacing: 3) { Text(row.author).font(.subheadline.bold()); Text(row.body); Text(ServiceOpsDate.format(row.createdAt)).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding().background(.white, in: RoundedRectangle(cornerRadius: 12)) }
            HStack { TextField("Add a work note", text: $commentText, axis: .vertical).textFieldStyle(.roundedBorder); Button { Task { await add() } } label: { Image(systemName: "paperplane.fill") }.disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.task { await load() }
    }
    private func load() async { rows = (try? await ServiceOpsAPIClient(baseURLString: baseURL, token: token).comments(number: number)) ?? [] }
    private func add() async { let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }; if (try? await ServiceOpsAPIClient(baseURLString: baseURL, token: token).addComment(number: number, body: text)) != nil { commentText = ""; await load() } }
}
