import Foundation
import SwiftUI
import Combine

@MainActor
final class ServiceOpsStore: ObservableObject {
    @Published var tickets: [ServiceTicket] = []
    @Published var selectedTicket: ServiceTicket?
    @Published var isLoadingTickets = false
    @Published var isCheckingConnection = false
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var connectionMessage: String?

    func loadTickets(baseURL: String, token: String, filter: TicketTypeFilter) async {
        isLoadingTickets = true
        defer { isLoadingTickets = false }

        do {
            let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: token)
            let page = try await client.listTickets(type: filter.apiKind, limit: 100)
            tickets = page.data
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
            connectionMessage = "Connected to \(info.info.title) API \(info.info.version)."
            errorMessage = nil
        } catch {
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
