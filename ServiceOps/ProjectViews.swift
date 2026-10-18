import SwiftUI

/// Projects the signed-in user may open (`/api/v1/projects`).
struct ProjectsView: View {
    let baseURL: String
    let token: String
    @State private var projects: [ProjectSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List(projects.filter { !$0.archived }) { project in
            NavigationLink {
                WorkItemsView(project: project, baseURL: baseURL, token: token)
            } label: {
                HStack(spacing: 12) {
                    Text(project.key)
                        .font(.caption.weight(.bold).monospaced())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(ServiceOpsTheme.tealDark, in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name).font(.headline)
                        if let lead = project.lead { Text("Lead: \(lead)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle("Projects")
        .overlay {
            if isLoading && projects.isEmpty {
                ProgressView()
            } else if projects.isEmpty {
                ContentUnavailableView("No projects", systemImage: "square.stack.3d.up",
                                       description: Text(errorMessage ?? "Projects you're a member of appear here."))
            }
        }
        .refreshable { await load() }
        .task { if projects.isEmpty { await load() } }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            projects = try await ServiceOpsAPIClient(baseURLString: baseURL, token: token).projects()
            errorMessage = nil
        } catch let error as ServiceOpsAPIError where error.statusCode == 404 {
            projects = []
            errorMessage = "Projects are turned off on this server."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A project's work items, open first, with search.
struct WorkItemsView: View {
    let project: ProjectSummary
    let baseURL: String
    let token: String
    @State private var items: [WorkItem] = []
    @State private var query = ""
    @State private var showDone = false
    @State private var errorMessage: String?

    private var visible: [WorkItem] { showDone ? items : items.filter { !$0.isDone } }

    var body: some View {
        List {
            Toggle("Show done", isOn: $showDone)
            ForEach(visible) { item in
                NavigationLink {
                    WorkItemDetailView(key: item.key, baseURL: baseURL, token: token, statuses: project.statuses)
                } label: {
                    WorkItemRow(item: item)
                }
            }
        }
        .navigationTitle(project.name)
        .searchable(text: $query, prompt: "Key or title")
        .overlay {
            if visible.isEmpty {
                ContentUnavailableView("No work items", systemImage: "checklist", description: Text(errorMessage ?? ""))
            }
        }
        .refreshable { await load() }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            await load()
        }
    }

    private func load() async {
        do {
            let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: token)
            var loaded: [WorkItem] = []
            var cursor: Int?
            // Pages of 100 in key order; a bounded number keeps large projects responsive.
            for _ in 0..<5 {
                let page = try await client.workItems(project: project.key, query: query, cursor: cursor)
                loaded.append(contentsOf: page.data)
                guard let next = page.meta.nextCursor else { break }
                cursor = next
            }
            items = loaded
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct WorkItemRow: View {
    let item: WorkItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.key).font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(ServiceOpsTheme.tealText)
                Text(item.type.capitalized).font(.caption2).foregroundStyle(.secondary)
                if item.flagged { Image(systemName: "flag.fill").font(.caption2).foregroundStyle(.red) }
                Spacer()
                WorkItemStatusBadge(status: item.status)
            }
            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            HStack(spacing: 10) {
                Label(item.priority.capitalized, systemImage: "arrow.up.arrow.down")
                if !item.assignees.isEmpty { Label(item.assignees.joined(separator: ", "), systemImage: "person") }
                if let due = item.dueDate { Label(due, systemImage: "calendar") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

private struct WorkItemStatusBadge: View {
    let status: ProjectStatus

    var body: some View {
        Text(status.name)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(status.category == "done" ? ServiceOpsTheme.greenText : ServiceOpsTheme.ink)
            .background(status.category == "in_progress" ? ServiceOpsTheme.amber.opacity(0.2) : ServiceOpsTheme.badgeBackground,
                        in: Capsule())
    }
}

/// One work item: details, status change and comments.
struct WorkItemDetailView: View {
    let key: String
    let baseURL: String
    let token: String
    /// The project's statuses; loaded with the item when not supplied.
    var statuses: [ProjectStatus] = []
    @State private var item: WorkItem?
    @State private var projectStatuses: [ProjectStatus] = []
    @State private var comment = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let item {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.key).font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(ServiceOpsTheme.tealText)
                        Text(item.title).font(.title3.weight(.bold))
                    }
                    Picker("Status", selection: Binding(get: { item.status.id }, set: { id in Task { await move(to: id) } })) {
                        ForEach(projectStatuses) { status in Text(status.name).tag(status.id) }
                    }
                    .disabled(isSaving || projectStatuses.isEmpty)
                    LabeledContent("Type", value: item.type.capitalized)
                    LabeledContent("Priority", value: item.priority.capitalized)
                    LabeledContent("Assignees", value: item.assignees.isEmpty ? "Unassigned" : item.assignees.joined(separator: ", "))
                    if let reporter = item.reporter { LabeledContent("Reporter", value: reporter) }
                    if let parent = item.parent { LabeledContent("Parent", value: parent) }
                    if let due = item.dueDate { LabeledContent("Due", value: due) }
                    if let points = item.storyPoints { LabeledContent("Story points", value: points.formatted()) }
                    if !item.labels.isEmpty { LabeledContent("Labels", value: item.labels.joined(separator: ", ")) }
                }
                if let description = item.description, !description.isEmpty {
                    Section("Description") { Text(description).font(.subheadline) }
                }
                Section("Comments") {
                    ForEach(item.comments ?? []) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.author).font(.subheadline.bold())
                            Text(row.body).font(.subheadline)
                            Text(ServiceOpsDate.format(row.createdAt)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        TextField("Add a comment", text: $comment, axis: .vertical)
                        Button { Task { await addComment() } } label: { Image(systemName: "paperplane.fill") }
                            .disabled(isSaving || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("Send comment")
                    }
                }
            } else if errorMessage == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(key)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if item == nil { await load() } }
        .alert("ServiceOps", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func load() async {
        do {
            let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: token)
            let loaded = try await client.workItem(key: key)
            item = loaded
            if !statuses.isEmpty {
                projectStatuses = statuses
            } else if projectStatuses.isEmpty {
                projectStatuses = try await client.project(key: loaded.project).statuses
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func move(to statusID: Int) async {
        guard let item, statusID != item.status.id else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await ServiceOpsAPIClient(baseURLString: baseURL, token: token).moveWorkItem(key: key, statusID: statusID)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addComment() async {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await ServiceOpsAPIClient(baseURLString: baseURL, token: token).addWorkItemComment(key: key, body: text)
            comment = ""
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
