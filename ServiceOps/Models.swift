import Foundation

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

struct MobileUser: Codable {
    let id: Int
    let username: String
    let name: String
}

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
