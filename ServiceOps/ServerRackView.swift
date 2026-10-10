import OSLog
import SwiftUI

private let rackLogger = Logger(subsystem: "wijesundara.com.ServiceOps", category: "Rack")

/// Full rack elevation, matching the web rack view: front/rear faces drawn U1 at the bottom,
/// the selected device highlighted, rack totals, and devices that can't be drawn listed separately.
struct ServerRackView: View {
    let rackID: Int
    let selectedAssetID: Int
    let baseURL: String
    let token: String
    @State private var rack: RackDocument?
    @State private var face = "front"
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var truncated = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Button("Retry") { Task { await load() } }
                    }
                    if loading && rack == nil { ProgressView("Loading rack").frame(maxWidth: .infinity) }
                    if let rack {
                        header(rack)
                        if let stats = rack.stats { RackStatsPanel(stats: stats) }
                        Picker("Rack face", selection: $face) {
                            Text("Front").tag("front")
                            Text("Rear").tag("rear")
                        }.pickerStyle(.segmented)
                        if RackLayout.hasOverlap(capacity: rack.capacity, placements: rack.mounted(face: face)
                            .map { (position: $0.position, height: Optional($0.uHeight ?? 1)) }) {
                            Label("Recorded placements overlap on this face. Review the device list for all affected devices.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if rack.capacity > 0 && rack.capacity <= 120 {
                            RackElevation(rack: rack, face: face, selectedAssetID: selectedAssetID)
                        } else {
                            Text("Rack capacity is missing or outside the supported drawing range (1–120 U).")
                                .foregroundStyle(.secondary)
                        }
                        Text("Only devices you can read are shown. Unmarked spaces do not prove that a rack unit is empty.")
                            .font(.caption).foregroundStyle(.secondary)
                        if truncated {
                            Label("The server returned only the first 1,000 readable devices. This view is incomplete.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        notDrawnList(rack)
                        deviceList(rack)
                    }
                }.padding()
            }
            .onChange(of: rack?.id) {
                // Bring the selected device into view, like the web view scrolling to the highlight.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation { proxy.scrollTo(RackElevation.anchorID(selectedAssetID), anchor: .center) }
                }
            }
        }
        .navigationTitle("Rack view")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func header(_ rack: RackDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(rack.name).font(.title2.bold())
            Label(rack.site.isEmpty ? "Site not recorded" : rack.site, systemImage: "mappin.and.ellipse")
            Text("\(rack.capacity) U · \(rack.active ? "Active" : "Inactive") · \(rack.assets.count) readable devices")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 0U equipment (typically PDUs) and devices whose placement is missing or out of bounds,
    /// as the web view's "PDUs" and "Unplaced" panels show them.
    @ViewBuilder
    private func notDrawnList(_ rack: RackDocument) -> some View {
        let notDrawn = rack.assets.filter { !rack.isMounted($0) }
        if !notDrawn.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Not drawn in the elevation").font(.headline)
                ForEach(notDrawn) { asset in
                    HStack(spacing: 10) {
                        RackDeviceGlyph(asset: asset, selected: asset.id == selectedAssetID)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(asset.name).font(.subheadline.bold())
                            Text(asset.placementNote ?? "Position, height or face is missing or invalid")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func deviceList(_ rack: RackDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Devices and placement").font(.headline)
            ForEach(rack.assets) { asset in
                HStack(alignment: .top, spacing: 12) {
                    RackDeviceGlyph(asset: asset, selected: asset.id == selectedAssetID)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(asset.name).font(.subheadline.bold())
                        Text([asset.ciClass, asset.status, [asset.vendor, asset.model].compactMap { $0 }.joined(separator: " ")]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(placementLabel(asset, rack: rack))
                            .font(.caption).foregroundStyle(.secondary)
                        if let ip = asset.ipAddress, !ip.isEmpty {
                            Text(ip).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding()
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    if asset.id == selectedAssetID {
                        RoundedRectangle(cornerRadius: 10).stroke(RackPalette.highlight, lineWidth: 2)
                    }
                }
            }
        }
    }

    private func placementLabel(_ asset: RackAsset, rack: RackDocument) -> String {
        guard rack.isMounted(asset), let position = asset.position else {
            return asset.placementNote ?? "Unplaced: position, height or face is missing or invalid"
        }
        return "U\(String(format: "%g", position)) · \(asset.uHeight ?? 1) U · \(asset.face?.capitalized ?? "Front")"
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await ServiceOpsAPIClient(baseURLString: baseURL, token: token).rack(id: rackID)
            guard !Task.isCancelled else { return }
            rack = result.data
            truncated = result.meta.truncated
            if let selected = result.data.assets.first(where: { $0.id == selectedAssetID }),
               let selectedFace = selected.face?.lowercased(), ["front", "rear"].contains(selectedFace) {
                face = selectedFace
            }
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            rackLogger.error("Rack lookup failed")
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Ticket placement panel

/// The ticket's "Rack & network placement" panel: the first rack-mounted CI (primary CI first)
/// with a compact elevation around it, a link to the full rack view, and any other mounted CIs.
/// Staff always see the panel, so a server that can't share placements yet is explained rather
/// than leaving the ticket with no route to the server location.
struct TicketRackPlacementPanel: View {
    let number: String
    let baseURL: String
    let token: String
    /// Whether the user may read the CMDB (agents and above); others never see rack details.
    let canViewCMDB: Bool

    private enum LoadState {
        case loading
        case loaded([TicketRackPlacement])
        /// The server predates ticket rack placements.
        case unsupported
        case failed(String)
    }

    @State private var state = LoadState.loading
    @State private var previewRack: RackDocument?
    @State private var previewFailed = false

    var body: some View {
        Group {
            if canViewCMDB {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task(id: "\(number)-\(canViewCMDB)") {
            guard canViewCMDB else { return }
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state {
            case .loading:
                title(subtitle: nil)
                ProgressView().frame(maxWidth: .infinity)
            case .loaded(let placements):
                if let first = placements.first {
                    placementContent(first: first, others: Array(placements.dropFirst()))
                } else {
                    title(subtitle: "No linked configuration item has a recorded rack position.")
                    findInCMDBLink
                }
            case .unsupported:
                title(subtitle: "This ServiceOps server doesn't share ticket rack locations with the app yet. Update the server to see where this ticket's servers sit, or look the device up in Servers and assets.")
                findInCMDBLink
            case .failed(let message):
                title(subtitle: nil)
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Retry") { Task { await load() } }
            }
        }
    }

    private func title(subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Rack & network placement").font(.headline)
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var findInCMDBLink: some View {
        NavigationLink {
            CMDBView(baseURL: baseURL, token: token)
        } label: {
            Label("Find in servers and assets", systemImage: "magnifyingglass")
        }
    }

    @ViewBuilder
    private func placementContent(first: TicketRackPlacement, others: [TicketRackPlacement]) -> some View {
        title(subtitle: "\(first.ci.name) · \(first.label)")
        if let previewRack, previewRack.capacity > 0, previewRack.capacity <= 120 {
            let face = previewRack.assets.first { $0.id == first.ci.id }?.face?.lowercased()
                ?? first.rack.face?.lowercased() ?? "front"
            Text(face == "rear" ? "Rear" : "Front")
                .font(.caption2.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
            RackElevation(rack: previewRack, face: face == "rear" ? "rear" : "front", selectedAssetID: first.ci.id,
                          window: RackElevation.window(around: first.ci.id, in: previewRack), unitHeight: 24)
        } else if previewFailed {
            Label("The rack preview couldn't be loaded.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.secondary)
        } else if first.rack.id != nil {
            ProgressView().frame(maxWidth: .infinity)
        }
        if let rackID = first.rack.id {
            NavigationLink {
                ServerRackView(rackID: rackID, selectedAssetID: first.ci.id, baseURL: baseURL, token: token)
            } label: {
                Label("Open full rack view", systemImage: "server.rack")
            }
        }
        if !others.isEmpty {
            Divider()
            ForEach(others) { other in
                if let otherRackID = other.rack.id {
                    NavigationLink {
                        ServerRackView(rackID: otherRackID, selectedAssetID: other.ci.id, baseURL: baseURL, token: token)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(other.ci.name).font(.subheadline.bold())
                            Text(other.label).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        if case .loaded = state {} else { state = .loading }
        do {
            let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: token)
            guard let envelope = try await client.ticketRackPlacements(number: number) else {
                state = .unsupported
                return
            }
            guard !Task.isCancelled else { return }
            state = .loaded(envelope.data)
            previewFailed = false
            if let rackID = envelope.data.first?.rack.id {
                do {
                    previewRack = try await client.rack(id: rackID).data
                } catch {
                    guard !Task.isCancelled else { return }
                    rackLogger.error("Ticket rack preview lookup failed")
                    previewFailed = true
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            rackLogger.error("Ticket rack placement lookup failed")
            state = .failed((error as? ServiceOpsAPIError)?.serverMessage ?? error.localizedDescription)
        }
    }
}

// MARK: - Elevation drawing

/// Draws one rack face. With `window`, only those units are drawn (the compact preview).
struct RackElevation: View {
    let rack: RackDocument
    let face: String
    let selectedAssetID: Int
    var window: ClosedRange<Int>?
    var unitHeight: CGFloat = 30
    private let railWidth: CGFloat = 34

    static func anchorID(_ assetID: Int) -> String { "rack-device-\(assetID)" }

    /// ±5 U around the selected device, as the web's embedded preview does.
    static func window(around assetID: Int, in rack: RackDocument) -> ClosedRange<Int>? {
        guard let asset = rack.assets.first(where: { $0.id == assetID }), rack.isMounted(asset),
              let position = asset.position else { return nil }
        let bottom = max(1, Int(position.rounded(.down)) - 5)
        let top = min(rack.capacity, Int(position.rounded(.up)) + (asset.uHeight ?? 1) - 1 + 5)
        return bottom <= top ? bottom...top : nil
    }

    private var units: ClosedRange<Int> { window ?? 1...rack.capacity }

    var body: some View {
        let devices = rack.mounted(face: face)
        GeometryReader { geometry in
            let deviceWidth = max(geometry.size.width - railWidth * 2, 1)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(units.reversed(), id: \.self) { unit in
                        HStack(spacing: 0) {
                            railLabel(unit)
                            Rectangle().fill(RackPalette.slot)
                                .overlay(alignment: .bottom) { Rectangle().fill(RackPalette.slotLine).frame(height: 0.5) }
                            railLabel(unit)
                        }.frame(height: unitHeight)
                    }
                }
                ForEach(devices) { asset in
                    if let frame = frame(of: asset) {
                        RackDeviceBlock(asset: asset, selected: asset.id == selectedAssetID,
                                        dimmed: devices.contains { $0.id == selectedAssetID } && asset.id != selectedAssetID,
                                        height: frame.height)
                            .frame(width: deviceWidth - 4, height: frame.height)
                            .offset(x: railWidth + 2, y: frame.minY)
                            .id(Self.anchorID(asset.id))
                            .zIndex(asset.id == selectedAssetID ? 1 : 0)
                    }
                }
            }
        }
        .frame(height: CGFloat(units.count) * unitHeight)
        .padding(6)
        .background(RackPalette.chassis, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rack.name) \(face) elevation")
    }

    private func railLabel(_ unit: Int) -> some View {
        Text("\(unit)")
            .font(.system(size: unitHeight < 28 ? 8 : 9, design: .monospaced))
            .foregroundStyle(RackPalette.railText)
            .frame(width: railWidth, height: unitHeight)
            .background(RackPalette.rail)
    }

    /// Top-based frame inside the drawn units; partially visible devices are clipped by the window.
    private func frame(of asset: RackAsset) -> (minY: CGFloat, height: CGFloat)? {
        guard let position = asset.position else { return nil }
        let height = max(asset.uHeight ?? 1, 1)
        let deviceTop = position + Double(height) - 1
        guard deviceTop >= Double(units.lowerBound), position <= Double(units.upperBound) else { return nil }
        let minY = CGFloat(Double(units.upperBound) - deviceTop) * unitHeight
        return (minY + 1, CGFloat(height) * unitHeight - 2)
    }
}

private struct RackDeviceBlock: View {
    let asset: RackAsset
    let selected: Bool
    let dimmed: Bool
    let height: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: RackPalette.symbol(for: asset)).font(.caption)
            Text(asset.name).font(.caption.bold()).lineLimit(1)
            Spacer(minLength: 4)
            if height > 40 {
                Text(asset.status).font(.caption2).lineLimit(1).opacity(0.85)
            }
            Circle().fill(RackPalette.statusColor(asset.status)).frame(width: 6, height: 6)
        }
        .padding(.horizontal, 8)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RackPalette.fill(for: asset), in: RoundedRectangle(cornerRadius: 3))
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .stroke(selected ? RackPalette.highlight : .white.opacity(0.12), lineWidth: selected ? 2.5 : 0.5)
        }
        .shadow(color: selected ? RackPalette.highlight.opacity(0.7) : .clear, radius: 6)
        .opacity(dimmed ? 0.72 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(asset.name), U\(asset.position.map { String(format: "%g", $0) } ?? "?"), \(asset.uHeight ?? 1) rack units, \(asset.face ?? "front"), \(asset.status)\(selected ? ", selected device" : "")")
    }
}

private struct RackDeviceGlyph: View {
    let asset: RackAsset
    let selected: Bool

    var body: some View {
        Image(systemName: selected ? "arrow.right.circle.fill" : RackPalette.symbol(for: asset))
            .font(.subheadline)
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(selected ? RackPalette.highlightFill : RackPalette.fill(for: asset), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
    }
}

/// Rack drawing colors. The rack itself is drawn as dark hardware in both light and dark
/// appearance; device colors follow the web rack view's class colors.
enum RackPalette {
    static let chassis = Color(red: 0.11, green: 0.13, blue: 0.15)
    static let rail = Color(red: 0.16, green: 0.18, blue: 0.20)
    static let railText = Color(white: 0.62)
    static let slot = Color(red: 0.07, green: 0.08, blue: 0.10)
    static let slotLine = Color(white: 1, opacity: 0.06)
    static let highlight = Color(red: 0.35, green: 0.90, blue: 0.80)
    static let highlightFill = Color(red: 0.00, green: 0.57, blue: 0.48)

    /// Same rule as the web's `colorFor(ci_class)`.
    static func fill(for asset: RackAsset) -> Color {
        let key = asset.ciClass.lowercased()
        if key.contains("switch") || key.contains("router") { return Color(red: 0.98, green: 0.67, blue: 0.24) }
        if key == "pdu" || asset.kind == "pdu" { return Color(red: 0.75, green: 0.22, blue: 0.17) }
        if key.contains("storage") { return Color(red: 0.49, green: 0.36, blue: 0.75) }
        return Color(red: 0.00, green: 0.24, blue: 0.30)
    }

    static func symbol(for asset: RackAsset) -> String {
        switch asset.kind {
        case "switch", "router", "load-balancer": "network"
        case "firewall": "shield.lefthalf.filled"
        case "storage": "externaldrive.fill"
        case "pdu": "powerplug.fill"
        case "ups": "battery.100percent"
        case "patch-panel": "cable.connector"
        case "kvm": "keyboard"
        case "cooling": "fan.fill"
        case "blade": "square.stack.3d.up.fill"
        default: "server.rack"
        }
    }

    static func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "operational": .green
        case "degraded", "maintenance": .yellow
        case "down": .red
        default: .gray
        }
    }
}

extension RackDocument {
    /// Mounted devices are those the server gives no placement note (web rule), and that
    /// fit inside the rack.
    func isMounted(_ asset: RackAsset) -> Bool {
        asset.placementNote == nil
            && RackLayout.offset(capacity: capacity, position: asset.position, height: asset.uHeight ?? 1) != nil
    }

    func mounted(face: String) -> [RackAsset] {
        assets.filter { ($0.face?.lowercased() ?? "front") == face && isMounted($0) }
    }
}

#Preview("Rack elevation", traits: .sizeThatFitsLayout) {
    let devices = [
        RackAsset(id: 1, name: "core-sw-01", ciClass: "Network Switch", status: "Operational", ipAddress: "10.0.0.2",
                  vendor: "Juniper", model: "EX4400", position: 40, uHeight: 1, face: "front", kind: "switch", placementNote: nil),
        RackAsset(id: 2, name: "db-prod-01", ciClass: "Server", status: "Degraded", ipAddress: "10.0.1.10",
                  vendor: "Dell", model: "R750", position: 30, uHeight: 2, face: "front", kind: "server", placementNote: nil),
        RackAsset(id: 3, name: "san-a", ciClass: "Storage Array", status: "Operational", ipAddress: nil,
                  vendor: nil, model: nil, position: 24, uHeight: 4, face: "front", kind: "storage", placementNote: nil),
        RackAsset(id: 4, name: "pdu-a", ciClass: "PDU", status: "Operational", ipAddress: nil,
                  vendor: nil, model: nil, position: nil, uHeight: 0, face: "rear", kind: "pdu", placementNote: "0U equipment"),
    ]
    let rack = RackDocument(id: 1, name: "B4-12", site: "Tokyo DC1", capacity: 42, active: true,
                            stats: RackStats(spaceUsedU: 7, spaceTotalU: 42, weightKg: nil, powerWatts: 1450), assets: devices)
    VStack(spacing: 16) {
        RackElevation(rack: rack, face: "front", selectedAssetID: 2,
                      window: RackElevation.window(around: 2, in: rack), unitHeight: 24)
        RackStatsPanel(stats: rack.stats!)
    }
    .padding()
    .frame(width: 390)
    .background(ServiceOpsTheme.nowBackground)
    .preferredColorScheme(.dark)
}

private struct RackStatsPanel: View {
    let stats: RackStats

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Space").font(.caption).foregroundStyle(.secondary)
                Gauge(value: min(stats.spaceUsedU, Double(max(stats.spaceTotalU, 1))), in: 0...Double(max(stats.spaceTotalU, 1))) {
                    EmptyView()
                }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(RackPalette.highlightFill)
                Text("\(String(format: "%g", stats.spaceUsedU)) / \(stats.spaceTotalU) U (\(percent) %)")
                    .font(.caption.monospacedDigit())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            stat("Power", stats.powerWatts.map { "\(String(format: "%g", $0)) W" })
            stat("Weight", stats.weightKg.map { "\(String(format: "%g", $0)) kg" })
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var percent: Int {
        stats.spaceTotalU > 0 ? Int((stats.spaceUsedU / Double(stats.spaceTotalU) * 100).rounded()) : 0
    }

    private func stat(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "Not tracked").font(.subheadline.monospacedDigit())
                .foregroundStyle(value == nil ? .secondary : .primary)
        }
    }
}
