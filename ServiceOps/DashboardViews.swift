import Charts
import SwiftUI

/// Where a dashboard widget leads.
enum DashboardRoute: Hashable {
    case list(title: String, reference: TicketListReference)
    case workItem(key: String)
    case approvals
}

/// The signed-in user's personal and team dashboards, as configured on the web.
struct DashboardsView: View {
    @ObservedObject var store: ServiceOpsStore
    @Binding var baseURL: String
    @Binding var apiToken: String
    @State private var listing: DashboardListing?
    @State private var selectedID: Int?
    @State private var document: DashboardDocument?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var personal: [DashboardSummary] { listing?.dashboards.filter { !$0.isTeam } ?? [] }
    private var team: [DashboardSummary] { listing?.dashboards.filter(\.isTeam) ?? [] }
    private var selected: DashboardSummary? { listing?.dashboards.first { $0.id == selectedID } }

    var body: some View {
        ZStack {
            ServiceOpsTheme.pageBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let document {
                        DashboardHeader(document: document)
                        if document.widgets.isEmpty {
                            ContentUnavailableView(
                                "This dashboard is empty", systemImage: "square.grid.2x2",
                                description: Text("Add widgets to it in ServiceOps on the web.")
                            )
                            .frame(minHeight: 220)
                        }
                        ForEach(document.widgets) { widget in
                            DashboardWidgetCard(widget: widget, baseURL: baseURL)
                        }
                    } else if isLoading {
                        ProgressView("Loading dashboard").frame(maxWidth: .infinity, minHeight: 240)
                    } else if errorMessage != nil {
                        ContentUnavailableView("Dashboard unavailable", systemImage: "exclamationmark.triangle",
                                               description: Text(errorMessage ?? ""))
                    }
                }
                .padding(16)
            }
            .refreshable { await load() }
        }
        .navigationTitle(selected?.name ?? "Dashboards")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !personal.isEmpty {
                        Section("Mine") { ForEach(personal) { picker(for: $0) } }
                    }
                    ForEach(Dictionary(grouping: team, by: { $0.group?.name ?? "Team" }).sorted(by: { $0.key < $1.key }), id: \.key) { group in
                        Section(group.key) { ForEach(group.value) { picker(for: $0) } }
                    }
                } label: {
                    Label("Choose dashboard", systemImage: "rectangle.stack")
                }
                .disabled(listing == nil)
            }
        }
        .navigationDestination(for: DashboardRoute.self) { route in
            switch route {
            case .list(let title, let reference):
                DashboardTicketListView(title: title, reference: reference, store: store,
                                        baseURL: $baseURL, apiToken: $apiToken)
            case .workItem(let key):
                WorkItemDetailView(key: key, baseURL: baseURL, token: apiToken)
            case .approvals:
                ApprovalsView(baseURL: baseURL, token: apiToken)
            }
        }
        .navigationDestination(for: ServiceTicket.self) { ticket in
            TicketDetailView(ticket: ticket, store: store, baseURL: $baseURL, apiToken: $apiToken)
        }
        .task { if listing == nil { await load() } }
        .onChange(of: selectedID) { _, _ in Task { await loadSelected() } }
    }

    private func picker(for dashboard: DashboardSummary) -> some View {
        Button {
            selectedID = dashboard.id
        } label: {
            if dashboard.id == selectedID {
                Label(dashboard.name, systemImage: "checkmark")
            } else {
                Text(dashboard.home ? "\(dashboard.name) ★" : dashboard.name)
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: apiToken)
            let fresh = try await client.dashboards()
            listing = fresh
            // Keep the open dashboard if it still exists; otherwise open the home one.
            if selectedID == nil || !fresh.dashboards.contains(where: { $0.id == selectedID }) {
                selectedID = fresh.homeId
            }
            document = try await client.dashboard(id: selectedID ?? fresh.homeId)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadSelected() async {
        guard let selectedID, document?.id != selectedID else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            document = try await ServiceOpsAPIClient(baseURLString: baseURL, token: apiToken).dashboard(id: selectedID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DashboardHeader: View {
    let document: DashboardDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(document.group.map { "TEAM DASHBOARD · \($0.name.uppercased())" } ?? "MY DASHBOARD")
                .font(.caption2.weight(.bold))
                .foregroundStyle(ServiceOpsTheme.greenText)
            Text(document.name)
                .font(.title2.weight(.bold))
                .foregroundStyle(ServiceOpsTheme.ink)
            if !document.description.isEmpty {
                Text(document.description).font(.subheadline).foregroundStyle(ServiceOpsTheme.muted)
            }
            Text(document.group == nil ? "Only you can see this dashboard" : "Each person sees only records they may open")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One widget, drawn according to its `view`.
private struct DashboardWidgetCard: View {
    let widget: DashboardWidget
    let baseURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(widget.title)
                    .font(.headline)
                    .foregroundStyle(ServiceOpsTheme.tealText)
                if let team = widget.team {
                    Text(team.name)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(ServiceOpsTheme.badgeBackground, in: Capsule())
                }
                Spacer()
                if let list = widget.list, widget.view == "tickets" {
                    NavigationLink("View all", value: DashboardRoute.list(title: widget.title, reference: list))
                        .font(.caption.weight(.semibold))
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(ServiceOpsTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ServiceOpsTheme.cardLine))
    }

    @ViewBuilder
    private var content: some View {
        switch widget.view {
        case "tiles": tiles
        case "tickets": tickets(widget.tickets ?? [])
        case "bars": bars
        case "trend": trend
        case "workload": workload
        case "tasks":
            rows(widget.tasks ?? [], empty: "No open tasks") { task in
                DashboardTextRow(title: task.title, detail: "\(task.number) · \(task.state)", date: task.dueAt)
            }
        case "approvals":
            rows(widget.approvals ?? [], empty: "Nothing awaits your decision") { approval in
                NavigationLink(value: DashboardRoute.approvals) {
                    DashboardTextRow(title: approval.title ?? approval.number, detail: "\(approval.number) · \(approval.gate)", date: nil)
                }
                .buttonStyle(.plain)
            }
        case "changes":
            rows(widget.changes ?? [], empty: "No changes planned in this window") { change in
                NavigationLink(value: change.ticket) {
                    DashboardTextRow(title: change.ticket.title, detail: "\(change.ticket.number) · \(change.ticket.state)",
                                     date: change.plannedStart)
                }
                .buttonStyle(.plain)
            }
        case "requests":
            rows(widget.requests ?? [], empty: "No requests") { request in
                DashboardTextRow(title: request.title, detail: "\(request.number) · \(request.state)", date: request.dueAt)
            }
        case "articles":
            rows(widget.articles ?? [], empty: "No new articles") { article in
                DashboardTextRow(title: article.title, detail: article.category, date: article.createdAt)
            }
        case "work_items":
            if widget.disabled == true {
                Text("Projects are turned off on this server.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                rows(widget.workItems ?? [], empty: "No open work items") { item in
                    NavigationLink(value: DashboardRoute.workItem(key: item.key)) {
                        DashboardTextRow(title: item.title, detail: "\(item.key) · \(item.status.name)", date: item.dueDate)
                    }
                    .buttonStyle(.plain)
                }
            }
        case "notifications":
            rows(widget.notifications ?? [], empty: "No notifications") { notice in
                DashboardTextRow(title: notice.title, detail: notice.body, date: notice.createdAt)
                    .fontWeight(notice.read ? .regular : .semibold)
            }
        case "links":
            rows(widget.links ?? [], empty: "No links") { link in
                if let url = webURL(link.url) {
                    Link(destination: url) {
                        Label(link.label, systemImage: "arrow.up.right.square").font(.subheadline)
                    }
                } else {
                    Text(link.label).font(.subheadline)
                }
            }
        case "note":
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array((widget.paragraphs ?? []).enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph).font(.subheadline).foregroundStyle(ServiceOpsTheme.ink)
                }
            }
        default:
            Text("Open ServiceOps on the web to see this widget.").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(widget.tiles ?? [], id: \.label) { tile in
                if let list = tile.list {
                    NavigationLink(value: DashboardRoute.list(title: tile.label, reference: list)) { DashboardTile(tile: tile) }
                        .buttonStyle(PressableCardStyle())
                } else {
                    DashboardTile(tile: tile)
                }
            }
        }
    }

    @ViewBuilder
    private func tickets(_ rows: [ServiceTicket]) -> some View {
        if rows.isEmpty {
            Text("No matching records").font(.subheadline).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(rows) { ticket in
                    NavigationLink(value: ticket) { TicketRow(ticket: ticket) }
                        .buttonStyle(.plain)
                    if ticket.id != rows.last?.id { Divider() }
                }
            }
        }
    }

    @ViewBuilder
    private var bars: some View {
        let rows = widget.bars ?? []
        let peak = max(rows.map(\.count).max() ?? 1, 1)
        if rows.isEmpty {
            Text("No open records").font(.subheadline).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(rows, id: \.label) { bar in
                    if let list = bar.list {
                        NavigationLink(value: DashboardRoute.list(title: "\(widget.title): \(bar.label)", reference: list)) {
                            DashboardBarRow(bar: bar, peak: peak, tappable: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        DashboardBarRow(bar: bar, peak: peak, tappable: false)
                    }
                }
                if let total = widget.total, let list = widget.list {
                    NavigationLink(value: DashboardRoute.list(title: widget.title, reference: list)) {
                        Text("\(total) open in total").font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(widget.days ?? [], id: \.date) { day in
                BarMark(x: .value("Day", ServiceOpsDate.date(from: day.date + "T00:00:00Z") ?? .now, unit: .day),
                        y: .value("Opened", day.opened))
                    .foregroundStyle(by: .value("Series", "Opened"))
                    .position(by: .value("Series", "Opened"))
                BarMark(x: .value("Day", ServiceOpsDate.date(from: day.date + "T00:00:00Z") ?? .now, unit: .day),
                        y: .value("Resolved", day.resolved))
                    .foregroundStyle(by: .value("Series", "Resolved"))
                    .position(by: .value("Series", "Resolved"))
            }
            .chartForegroundStyleScale(["Opened": ServiceOpsTheme.amber, "Resolved": ServiceOpsTheme.brandGreen])
            .frame(height: 160)
            Text("\(widget.openedTotal ?? 0) opened · \(widget.resolvedTotal ?? 0) resolved")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var workload: some View {
        if widget.missingTeam == true {
            Text("Choose a team for this widget on the web.").font(.subheadline).foregroundStyle(.secondary)
        } else {
            rows(widget.members ?? [], empty: "No team members") { member in
                let label = HStack {
                    Text(member.person?.name ?? "Unknown").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(member.tickets) tickets · \(member.tasks) tasks")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let list = member.list {
                    NavigationLink(value: DashboardRoute.list(title: member.person?.name ?? widget.title, reference: list)) { label }
                        .buttonStyle(.plain)
                } else {
                    label
                }
            }
        }
    }

    @ViewBuilder
    private func rows<Row: Hashable, Content: View>(_ items: [Row], empty: String,
                                                    @ViewBuilder row: @escaping (Row) -> Content) -> some View {
        if items.isEmpty {
            Text(empty).font(.subheadline).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items, id: \.self) { item in row(item) }
            }
        }
    }

    /// Web links stay on the ServiceOps server.
    private func webURL(_ path: String) -> URL? {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), let base = URL(string: baseURL) else { return nil }
        return URL(string: path, relativeTo: base)?.absoluteURL
    }
}

private struct DashboardTile: View {
    let tile: DashboardWidget.Tile

    private var color: Color {
        switch tile.tone {
        case "alert": .red
        case "warn": ServiceOpsTheme.amber
        default: ServiceOpsTheme.brandGreen
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(tile.count)")
                .font(.title2.weight(.bold)).monospacedDigit()
                .foregroundStyle(tile.tone.isEmpty ? ServiceOpsTheme.ink : color)
            Text(tile.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ServiceOpsTheme.muted)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ServiceOpsTheme.fieldBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 10)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tile.label), \(tile.count)")
        .accessibilityHint(tile.list == nil ? "" : "Opens the list")
    }
}

private struct DashboardBarRow: View {
    let bar: DashboardWidget.Bar
    let peak: Int
    let tappable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(bar.label).font(.caption.weight(.semibold)).foregroundStyle(ServiceOpsTheme.ink).lineLimit(1)
                Spacer()
                Text("\(bar.count)").font(.caption.weight(.bold).monospacedDigit())
                if tappable { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
            }
            ProgressView(value: Double(bar.count), total: Double(peak))
                .tint(ServiceOpsTheme.brandGreen)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bar.label), \(bar.count)")
    }
}

private struct DashboardTextRow: View {
    let title: String
    let detail: String
    let date: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(ServiceOpsTheme.ink).lineLimit(2)
            HStack(spacing: 6) {
                Text(detail).lineLimit(1)
                if let date { Text("· \(ServiceOpsDate.format(date))") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// The tickets behind a dashboard number; the count in the header is the number tapped.
struct DashboardTicketListView: View {
    let title: String
    let reference: TicketListReference
    @ObservedObject var store: ServiceOpsStore
    @Binding var baseURL: String
    @Binding var apiToken: String
    @State private var tickets: [ServiceTicket] = []
    @State private var total: Int?
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            ServiceOpsTheme.pageBackground.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 0) {
                    HStack {
                        Text(total.map { $0 == 1 ? "1 record" : "\($0) records" } ?? "Loading…")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ServiceOpsTheme.muted)
                        Spacer()
                    }
                    .padding(14)
                    TableHeaderRow()
                    ForEach(tickets) { ticket in
                        NavigationLink {
                            TicketDetailView(ticket: ticket, store: store, baseURL: $baseURL, apiToken: $apiToken)
                        } label: {
                            TicketRow(ticket: ticket)
                        }
                        .buttonStyle(.plain)
                        .task { if ticket.id == tickets.last?.id { await loadMore() } }
                        Divider().padding(.leading, 16)
                    }
                    if isLoading { ProgressView().padding() }
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red).padding()
                    } else if !isLoading && tickets.isEmpty && total != nil {
                        ContentUnavailableView("No matching records", systemImage: "tray").frame(minHeight: 220)
                    }
                }
                .background(ServiceOpsTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(16)
            }
            .refreshable { await reload() }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if total == nil { await reload() } }
    }

    private func reload() async {
        tickets = []
        nextCursor = nil
        total = nil
        await fetch(cursor: nil)
    }

    private func loadMore() async {
        guard let nextCursor, !isLoading else { return }
        await fetch(cursor: nextCursor)
    }

    private func fetch(cursor: String?) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await ServiceOpsAPIClient(baseURLString: baseURL, token: apiToken).ticketList(reference, cursor: cursor)
            tickets.append(contentsOf: page.data)
            total = page.meta.total
            nextCursor = page.meta.hasMore == false ? nil : page.meta.nextCursor
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
