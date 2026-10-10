import OSLog
import SwiftUI

private let assetLogger = Logger(subsystem: "wijesundara.com.ServiceOps", category: "Assets")

struct CMDBView: View {
    let baseURL: String
    let token: String
    @State private var rows: [ConfigurationItemSummary] = []
    @State private var query = ""
    @State private var selectedClass = "All"
    @State private var loading = false
    @State private var errorMessage: String?

    private var classes: [String] { ["All"] + Set(rows.map(\.ciClass)).sorted() }
    private var visibleRows: [ConfigurationItemSummary] {
        rows.filter { selectedClass == "All" || $0.ciClass == selectedClass }
    }

    var body: some View {
        List {
            Section {
                Picker("Asset type", selection: $selectedClass) {
                    ForEach(classes, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Displayed assets", value: String(visibleRows.count))
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Button("Retry") { Task { await load() } }
                }
            }
            if loading && rows.isEmpty {
                ProgressView("Loading assets")
            } else if visibleRows.isEmpty && errorMessage == nil {
                ContentUnavailableView("No matching assets", systemImage: "server.rack",
                                       description: Text("Search by name, IP address, serial number, location or rack."))
            }
            Section {
                ForEach(visibleRows) { row in
                    NavigationLink {
                        AssetDetailView(asset: row, baseURL: baseURL, token: token)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.name).font(.headline)
                            Text("\(row.ciClass) · \(row.environment) · \(row.status)")
                                .font(.caption).foregroundStyle(.secondary)
                            if let location = row.location, !location.isEmpty {
                                Label(location, systemImage: "mappin.and.ellipse").font(.subheadline)
                            } else if let rack = row.rack, !rack.site.isEmpty {
                                Label(rack.site, systemImage: "mappin.and.ellipse").font(.subheadline)
                            }
                            if let ip = row.ipAddress, !ip.isEmpty {
                                Text(ip).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            } footer: {
                Text("The server returns up to 100 matches. Narrow the search to find other assets. Blank fields mean the information has not been recorded or this server does not publish it.")
            }
        }
        .navigationTitle("Servers and assets")
        .searchable(text: $query, prompt: "Name, IP, serial, location or rack")
        .refreshable { await load() }
        .task(id: query) {
            do {
                try await Task.sleep(for: .milliseconds(250))
                await load()
            } catch is CancellationError {
                // A newer search owns the screen; preserve its results.
            } catch {
                assetLogger.error("Asset search scheduling failed")
                errorMessage = error.localizedDescription
            }
        }
    }

    private func load() async {
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        do {
            let result = try await ServiceOpsAPIClient(baseURLString: baseURL, token: token)
                .configurationItems(query: query)
            guard !Task.isCancelled else { return }
            rows = result
            if !classes.contains(selectedClass) { selectedClass = "All" }
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            assetLogger.error("Asset lookup failed")
            errorMessage = error.localizedDescription
        }
    }
}

private struct AssetDetailView: View {
    let asset: ConfigurationItemSummary
    let baseURL: String
    let token: String

    var body: some View {
        List {
            Section("Overview") {
                detail("Name", asset.name)
                detail("Class", asset.ciClass)
                detail("Environment", asset.environment)
                detail("Operational status", asset.status)
                detail("Lifecycle", asset.lifecycleState)
                detail("Business criticality", asset.businessCriticality)
                if let description = asset.description, !description.isEmpty {
                    Text(description).textSelection(.enabled)
                }
            }
            Section("Physical location") {
                detail("Location", asset.location)
                detail("Site", asset.rack?.site)
                detail("Rack", asset.rack?.name)
                detail("Rack position", asset.rack?.position.map { String(format: "%g U", $0) })
                detail("Rack height", asset.rack?.uHeight.map { "\($0) U" })
                detail("Rack face", asset.rack?.face)
                if let rackID = asset.rack?.id {
                    NavigationLink {
                        ServerRackView(rackID: rackID, selectedAssetID: asset.id,
                                       baseURL: baseURL, token: token)
                    } label: { Label("View rack", systemImage: "server.rack") }
                } else {
                    Text("A recorded rack assignment and an updated server are required for the rack view.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Network and hardware") {
                detail("IP address", asset.ipAddress)
                detail("Vendor", asset.vendor)
                detail("Model", asset.model)
                detail("Serial number", asset.serialNumber)
            }
            Section("Ownership and maintenance") {
                detail("Owner", asset.owner)
                detail("Support group", asset.supportGroup)
                detail("Installed", asset.installDate)
                detail("Warranty expires", asset.warrantyExpiryDate)
                detail("Last updated", asset.updatedAt.map(ServiceOpsDate.format))
            }
        }
        .navigationTitle(asset.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ title: String, _ value: String?) -> some View {
        LabeledContent(title) {
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "Not recorded")
                .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct ServerInformationView: View {
    @ObservedObject var store: ServiceOpsStore
    let baseURL: String

    private var components: URLComponents? { URLComponents(string: baseURL) }
    private var displayedURL: String {
        guard var url = components else { return "Invalid server address" }
        url.user = nil; url.password = nil; url.query = nil; url.fragment = nil
        return url.string ?? "Invalid server address"
    }

    var body: some View {
        List {
            Section("ServiceOps connection") {
                LabeledContent("Address", value: displayedURL).textSelection(.enabled)
                LabeledContent("Hostname", value: components?.host ?? "Unknown")
                LabeledContent("Transport", value: components?.scheme?.uppercased() ?? "Unknown")
                LabeledContent("Port", value: String(components?.port ?? (components?.scheme == "https" ? 443 : 80)))
                LabeledContent("API version", value: store.serverInfo?.info.version ?? "Not checked")
                if let message = store.connectionMessage {
                    Label(message, systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                Button {
                    Task { await store.checkConnection(baseURL: baseURL) }
                } label: {
                    if store.isCheckingConnection { ProgressView("Checking server") }
                    else { Label("Test connection", systemImage: "network") }
                }.disabled(store.isCheckingConnection)
                if let error = store.errorMessage, store.connectionMessage == nil {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            Section("Location") {
                Text("The connection address identifies the ServiceOps endpoint. Physical site and rack locations are recorded on each asset under Servers and assets; they cannot be inferred from a hostname.")
                    .foregroundStyle(.secondary)
            }
            Section("Installed app") {
                LabeledContent("Version", value: AppIdentity.version)
                LabeledContent("Build", value: AppIdentity.build)
            }
        }
        .navigationTitle("ServiceOps server")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.checkConnection(baseURL: baseURL) }
    }
}
