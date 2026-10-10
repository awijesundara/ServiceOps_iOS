import Foundation

enum AppIdentity {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    static let displayVersion = "Version \(version) (\(build))"
}

struct ServiceOpsAPIInfo: Decodable {
    let info: Info

    struct Info: Decodable {
        let title: String
        let version: String
    }
}

struct TicketPage: Decodable {
    let data: [ServiceTicket]
    let meta: PageMeta
}

struct TicketEnvelope: Decodable {
    let data: ServiceTicket
}

struct PageMeta: Decodable {
    let limit: Int
    let nextCursor: Int?
    let requestId: String?
}

struct ServiceTicket: Identifiable, Hashable, Decodable {
    let id: Int
    let number: String
    let type: TicketKind
    let title: String
    let description: String
    let state: String
    let priority: String
    let category: String
    let openedAt: String
    let updatedAt: String
    let internalDetails: InternalDetails?

    enum CodingKeys: String, CodingKey {
        case id
        case number
        case type
        case title
        case description
        case state
        case priority
        case category
        case openedAt
        case updatedAt
        case internalDetails = "internal"
    }

    var assignmentGroupName: String {
        internalDetails?.assignmentGroup?.name ?? "Unassigned group"
    }

    var assigneeName: String {
        internalDetails?.assignedTo?.name ?? "Unassigned"
    }
}

struct InternalDetails: Hashable, Decodable {
    let assignmentGroup: ServiceOpsPersonOrGroup?
    let assignedTo: ServiceOpsPersonOrGroup?
}

struct ServiceOpsPersonOrGroup: Hashable, Decodable {
    let id: Int
    let name: String
}

enum TicketKind: String, CaseIterable, Identifiable, Codable {
    case incident
    case change

    var id: String { rawValue }

    var title: String {
        switch self {
        case .incident: "Incidents"
        case .change: "Changes"
        }
    }
}

struct IncidentDraft: Encodable {
    let title: String
    let description: String
    let category: String
    let priority: String
    let assignmentGroupId: Int
}

struct TicketUpdateRequest: Encodable {
    let state: String?
    let priority: String?
}

struct MobileLoginRequest: Encodable {
    let username: String
    let password: String
    let provider: String
    let mfaCode: String?
}

struct MobileRefreshRequest: Encodable { let refreshToken: String }
struct MFACodeRequest: Encodable { let mfaCode: String? }
struct KeycloakExchangeRequest: Encodable { let code: String; let codeVerifier: String }

/// Sign-in methods enabled on the server (`GET /api/v1/auth/mobile/methods`).
struct MobileAuthMethods: Decodable, Equatable {
    let local: Bool
    let ldap: Bool
    let passkeys: Bool
    let keycloak: Bool
    let cloudflareAccess: Bool

    /// What servers without method discovery support: local/LDAP passwords and passkeys.
    static let legacy = MobileAuthMethods(local: true, ldap: true, passkeys: true, keycloak: false, cloudflareAccess: false)

    var password: Bool { local || ldap }
}

struct MobileAuthResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: MobileUser?
}

struct PasskeyOptionsEnvelope<Options: Decodable>: Decodable {
    let challengeId: String
    let options: Options
}

struct PasskeyRegistrationOptions: Decodable {
    let challenge: String
    let rp: PasskeyRelyingParty
    let user: PasskeyUser
}

struct PasskeyAuthenticationOptions: Decodable {
    let challenge: String
    let rpId: String
}

struct PasskeyRelyingParty: Decodable {
    let id: String
    let name: String
}

struct PasskeyUser: Decodable {
    let id: String
    let name: String
    let displayName: String
}

struct PasskeyCredentialPayload: Encodable {
    let id: String
    let rawId: String
    let type = "public-key"
    let response: PasskeyCredentialResponse
}

struct PasskeyCredentialResponse: Encodable {
    let clientDataJSON: String
    let attestationObject: String?
    let authenticatorData: String?
    let signature: String?
    let userHandle: String?
}

struct PasskeyRegistrationCompleteRequest: Encodable {
    let challengeId: String
    let credential: PasskeyCredentialPayload
    let name: String
}

struct PasskeyAuthenticationCompleteRequest: Encodable {
    let challengeId: String
    let credential: PasskeyCredentialPayload
}

struct PasskeyRecord: Decodable, Identifiable {
    let id: Int
    let name: String
    let createdAt: String?
    let lastUsedAt: String?
}

struct PasskeyListResponse: Decodable { let data: [PasskeyRecord] }

struct MobileUser: Codable {
    let id: Int
    let username: String
    let name: String
}

struct MobileBootstrapEnvelope: Decodable { let data: MobileBootstrap }
struct MobileBootstrap: Decodable {
    let user: MobileProfile
    let assignmentGroups: [ServiceOpsPersonOrGroup]
    let counts: MobileCounts
    let capabilities: MobileCapabilities
}
struct MobileProfile: Decodable { let id: Int; let username: String; let name: String; let role: String }
struct MobileCounts: Decodable { let pendingApprovals: Int; let unreadNotifications: Int }
struct MobileCapabilities: Decodable { let createIncident: Bool; let manageTickets: Bool; let viewCmdb: Bool }

struct MobileNotification: Identifiable, Decodable {
    let id: Int; let title: String; let body: String; let read: Bool
    let createdAt: String; let targetType: String?; let targetId: Int?
}
struct MobileApproval: Identifiable, Decodable {
    let id: Int; let state: String; let comments: String; let gate: String; let chain: String
    let targetType: String; let targetId: Int
}
struct KnowledgeArticle: Identifiable, Decodable {
    let id: Int; let title: String; let category: String; let body: String; let createdAt: String
}
struct ConfigurationItemSummary: Identifiable, Decodable {
    let id: Int; let name: String; let ciClass: String; let environment: String
    let status: String; let ipAddress: String?
    let description: String?
    let location: String?
    let serialNumber: String?
    let vendor: String?
    let model: String?
    let lifecycleState: String?
    let businessCriticality: String?
    let owner: String?
    let supportGroup: String?
    let installDate: String?
    let warrantyExpiryDate: String?
    let updatedAt: String?
    let rack: AssetRackLocation?
}

struct AssetRackLocation: Decodable {
    let id: Int?
    let capacity: Int?
    let name: String
    let site: String
    let position: Double?
    let uHeight: Int?
    let face: String?
}
struct TicketComment: Identifiable, Decodable {
    let id: Int; let body: String; let author: String; let createdAt: String
}
/// Attachment and CTASK documents use camelCase keys on the server, which
/// `convertFromSnakeCase` leaves unchanged.
struct TicketAttachment: Identifiable, Decodable {
    let id: Int; let fileName: String; let contentType: String
    let byteSize: Int; let createdAt: String; let downloadURL: String
}
struct ChangeTask: Identifiable, Decodable {
    let number: String; let title: String; let taskType: String; let state: String
    let required: Bool; let sequence: Int
    let assignmentGroup: String?; let assignee: String?
    let plannedStart: String?; let plannedEnd: String?; let workNotes: String
    var id: String { number }

    /// States this task may move to, mirroring the server's `OPERATIONAL_TASK_TRANSITIONS`.
    var stateOptions: [String] {
        switch state {
        case "Open": ["Open", "Work in Progress", "Pending", "Closed Complete", "Closed Incomplete", "Cancelled"]
        case "Work in Progress": ["Work in Progress", "Pending", "Closed Complete", "Closed Incomplete", "Cancelled"]
        case "Pending": ["Pending", "Work in Progress", "Closed Complete", "Closed Incomplete", "Cancelled"]
        default: [state]
        }
    }
}
struct ChangeTaskUpdateRequest: Encodable { let state: String?; let appendWorkNotes: String? }
struct DataEnvelope<Value: Decodable>: Decodable { let data: Value }
struct PushDeviceRequest: Encodable { let token: String; let deviceId: String; let environment: String }
struct ApprovalDecisionRequest: Encodable { let decision: String; let comments: String }
struct CommentRequest: Encodable { let body: String }

enum TicketTypeFilter: String, CaseIterable, Identifiable {
    case all
    case incidents
    case changes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .incidents: "Incidents"
        case .changes: "Changes"
        }
    }

    var apiKind: TicketKind? {
        switch self {
        case .all: nil
        case .incidents: .incident
        case .changes: .change
        }
    }
}

enum ServiceOpsPriority: String, CaseIterable, Identifiable {
    case p1 = "P1"
    case p2 = "P2"
    case p3 = "P3"
    case p4 = "P4"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .p1: "P1 Critical"
        case .p2: "P2 High"
        case .p3: "P3 Medium"
        case .p4: "P4 Low"
        }
    }
}

enum TicketState: String, CaseIterable, Identifiable {
    case new = "New"
    case inProgress = "In Progress"
    case pending = "Pending"
    case resolved = "Resolved"
    case closed = "Closed"
    case cancelled = "Cancelled"
    case approved = "Approved"
    case awaitingApproval = "Awaiting Approval"
    case rejected = "Rejected"

    var id: String { rawValue }

    /// States a ticket may move to from `current`, mirroring the server's
    /// `TICKET_TRANSITIONS` table so the picker never offers a move that returns 409.
    /// The current state is always first, even if this client does not recognise it.
    static func options(from current: String) -> [String] {
        let next: [TicketState]
        switch TicketState(rawValue: current) {
        case .new: next = [.new, .inProgress, .pending, .resolved, .cancelled]
        case .inProgress: next = [.inProgress, .pending, .resolved, .cancelled]
        case .pending: next = [.pending, .inProgress, .resolved, .cancelled]
        case .resolved: next = [.resolved, .inProgress, .closed]
        case .approved: next = [.approved, .inProgress, .cancelled]
        case .awaitingApproval: next = [.awaitingApproval, .cancelled]
        case .closed, .cancelled, .rejected, nil: next = []
        }
        let values = next.map(\.rawValue)
        return values.contains(current) ? values : [current] + values
    }
}

struct RackViewEnvelope: Decodable {
    let data: RackDocument
    let meta: RackViewMeta
}
struct RackViewMeta: Decodable { let truncated: Bool; let limit: Int }
struct RackDocument: Decodable {
    let id: Int
    let name: String
    let site: String
    let capacity: Int
    let active: Bool
    let stats: RackStats?
    let assets: [RackAsset]
}
/// Rack totals as the web rack view reports them (space is the union of mounted U ranges).
struct RackStats: Decodable {
    let spaceUsedU: Double
    let spaceTotalU: Int
    let weightKg: Double?
    let powerWatts: Double?
}
struct RackAsset: Decodable, Identifiable {
    let id: Int
    let name: String
    let ciClass: String
    let status: String
    let ipAddress: String?
    let vendor: String?
    let model: String?
    let position: Double?
    let uHeight: Int?
    let face: String?
    /// Equipment type from the server's identification (server, switch, pdu, …).
    let kind: String?
    /// Why the device isn't drawn in the elevation (for example "U position not recorded");
    /// `nil` when it is mounted. Older servers don't send it.
    let placementNote: String?
}

/// A rack-mounted CI linked to a ticket (`GET /api/v1/mobile/tickets/<n>/rack-placements`).
struct TicketRackPlacement: Decodable, Identifiable {
    struct LinkedCI: Decodable {
        let id: Int; let name: String; let ciClass: String; let status: String; let ipAddress: String?
    }
    let ci: LinkedCI
    let relationshipRole: String?
    let label: String
    let rack: AssetRackLocation
    var id: Int { ci.id }
}
struct TicketRackPlacementsEnvelope: Decodable {
    struct Meta: Decodable { let count: Int; let openOnAffectedCis: Bool }
    let data: [TicketRackPlacement]
    let meta: Meta
}
