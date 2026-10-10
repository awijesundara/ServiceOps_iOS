import Foundation
import SwiftUI
import Combine
import UIKit

@MainActor
final class ServiceOpsStore: ObservableObject {
    @Published var tickets: [ServiceTicket] = []
    @Published var selectedTicket: ServiceTicket?
    @Published var isLoadingTickets = false
    @Published var isCheckingConnection = false
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var connectionMessage: String?
    @Published var capabilities: MobileCapabilities?
    @Published var profile: MobileProfile?
    @Published var serverInfo: ServiceOpsAPIInfo?
    @Published var assignmentGroups: [ServiceOpsPersonOrGroup] = []
    @Published var pendingApprovals: Int?
    @Published var avatarImage: UIImage?

    private static let maxTicketPages = 20

    func tickets(in scope: TicketScope) -> [ServiceTicket] {
        let groupIDs = Set(assignmentGroups.map(\.id))
        return tickets.filter { scope.matches($0, userID: profile?.id, groupIDs: groupIDs) }
    }

    /// Loads the signed-in user's profile, capabilities, groups and counts, then their profile
    /// picture when the server has one. Returns the unread notification count for the badge.
    @discardableResult
    func loadBootstrap(baseURL: String, token: String) async -> Int? {
        guard let client = try? ServiceOpsAPIClient(baseURLString: baseURL, token: token),
              let bootstrap = try? await client.bootstrap() else { return nil }
        capabilities = bootstrap.capabilities
        profile = bootstrap.user
        assignmentGroups = bootstrap.assignmentGroups
        pendingApprovals = bootstrap.counts.pendingApprovals
        if bootstrap.user.hasAvatar == true {
            // Keep the current picture if this fetch fails; initials show only when there's none.
            if let data = try? await client.profileAvatar(), let image = UIImage(data: data) {
                avatarImage = image
            }
        } else {
            avatarImage = nil
        }
        return bootstrap.counts.unreadNotifications
    }

    func signOut() {
        tickets = []
        selectedTicket = nil
        capabilities = nil
        profile = nil
        serverInfo = nil
        assignmentGroups = []
        pendingApprovals = nil
        avatarImage = nil
    }

    func loadTickets(baseURL: String, token: String, filter: TicketTypeFilter) async {
        isLoadingTickets = true
        defer { isLoadingTickets = false }

        do {
            let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: token)
            // The server caps pages at 100 in ascending id order, so follow the
            // cursor to include newer records; stop after a bounded number of pages.
            var loaded: [ServiceTicket] = []
            var cursor: Int?
            for _ in 0..<Self.maxTicketPages {
                let page = try await client.listTickets(type: filter.apiKind, limit: 100, cursor: cursor)
                loaded.append(contentsOf: page.data)
                guard let next = page.meta.nextCursor, !page.data.isEmpty else { break }
                cursor = next
            }
            tickets = loaded
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshTicket(_ ticket: ServiceTicket, baseURL: String, token: String) async {
        do {
            let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: token)
            let envelope = try await client.ticket(number: ticket.number)
            selectedTicket = envelope.data
            replaceTicket(envelope.data)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createIncident(_ draft: IncidentDraft, baseURL: String, token: String) async -> Bool {
        isSaving = true
        defer { isSaving = false }

        do {
            let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: token)
            let envelope = try await client.createIncident(draft)
            replaceTicket(envelope.data)
            selectedTicket = envelope.data
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateTicket(_ ticket: ServiceTicket, state: String, priority: String, baseURL: String, token: String) async -> Bool {
        isSaving = true
        defer { isSaving = false }

        do {
            let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: token)
            let envelope = try await client.updateTicket(
                number: ticket.number,
                state: state == ticket.state ? nil : state,
                priority: priority == ticket.priority ? nil : priority
            )
            replaceTicket(envelope.data)
            selectedTicket = envelope.data
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func checkConnection(baseURL: String) async {
        isCheckingConnection = true
        defer { isCheckingConnection = false }

        do {
            let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: "")
            let info = try await client.checkConnection()
            serverInfo = info
            connectionMessage = "Connected to \(info.info.title) API \(info.info.version)."
            errorMessage = nil
        } catch {
            serverInfo = nil
            connectionMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    private func replaceTicket(_ ticket: ServiceTicket) {
        if let index = tickets.firstIndex(where: { $0.id == ticket.id }) {
            tickets[index] = ticket
        } else {
            tickets.insert(ticket, at: 0)
        }
    }
}
