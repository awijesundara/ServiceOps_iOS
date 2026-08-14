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
}
struct TicketComment: Identifiable, Decodable {
    let id: Int; let body: String; let author: String; let createdAt: String
}
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
    case resolved = "Resolved"
    case closed = "Closed"
    case cancelled = "Cancelled"

    var id: String { rawValue }
}
