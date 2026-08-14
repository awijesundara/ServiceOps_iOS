import Foundation

final class ServiceOpsAPIClient {
    private let baseURL: URL
    private var token: String
    private let session: URLSession

    init(baseURLString: String, token: String, session: URLSession = .shared) throws {
        let trimmedURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), url.scheme != nil, url.host != nil else {
            throw ServiceOpsAPIError.invalidConfiguration("Enter a valid ServiceOps server URL.")
        }
        self.baseURL = url
        let suppliedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = suppliedToken.isEmpty ? "" : SecureSessionStore.read(account: "accessToken") ?? suppliedToken
        self.session = session
    }

    func checkConnection() async throws -> ServiceOpsAPIInfo {
        try await send(path: "/api/v1/openapi.json", authenticated: false)
    }

    func login(username: String, password: String, provider: String, mfaCode: String?) async throws -> MobileAuthResponse {
        try await sendUnauthenticated(
            path: "/api/v1/auth/mobile/login",
            body: MobileLoginRequest(username: username, password: password, provider: provider, mfaCode: mfaCode)
        )
    }

    func refresh(refreshToken: String) async throws -> MobileAuthResponse {
        try await sendUnauthenticated(path: "/api/v1/auth/mobile/refresh", body: MobileRefreshRequest(refreshToken: refreshToken))
    }

    func logout() async throws {
        try await sendNoContent(path: "/api/v1/auth/mobile/logout", method: "POST")
    }

    func passkeyRegistrationOptions() async throws -> PasskeyOptionsEnvelope<PasskeyRegistrationOptions> {
        try await send(path: "/api/v1/auth/passkeys/register/options", method: "POST", bodyData: Data(), authenticated: true)
    }

    func completePasskeyRegistration(
        challengeId: String, credential: PasskeyCredentialPayload, name: String
    ) async throws -> PasskeyRecord {
        try await send(
            path: "/api/v1/auth/passkeys/register/complete", method: "POST",
            bodyData: JSONEncoder().encode(PasskeyRegistrationCompleteRequest(
                challengeId: challengeId, credential: credential, name: name
            )), authenticated: true
        )
    }

    func passkeyAuthenticationOptions() async throws -> PasskeyOptionsEnvelope<PasskeyAuthenticationOptions> {
        try await send(path: "/api/v1/auth/passkeys/authenticate/options", method: "POST", bodyData: Data(), authenticated: false)
    }

    func completePasskeyAuthentication(
        challengeId: String, credential: PasskeyCredentialPayload
    ) async throws -> MobileAuthResponse {
        try await send(
            path: "/api/v1/auth/passkeys/authenticate/complete", method: "POST",
            bodyData: JSONEncoder().encode(PasskeyAuthenticationCompleteRequest(
                challengeId: challengeId, credential: credential
            )), authenticated: false
        )
    }

    func listPasskeys() async throws -> [PasskeyRecord] {
        let response: PasskeyListResponse = try await send(path: "/api/v1/auth/passkeys")
        return response.data
    }

    func deletePasskey(id: Int) async throws {
        try await sendNoContent(path: "/api/v1/auth/passkeys/\(id)", method: "DELETE")
    }

    private func sendNoContent(path: String, method: String) async throws {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = joinedPath(baseURL.path, path)
        guard let url = components?.url else { throw ServiceOpsAPIError.invalidConfiguration("The ServiceOps server URL is invalid.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ServiceOpsAPIError.transport("ServiceOps could not revoke the mobile session.")
        }
    }

    private func sendUnauthenticated<Body: Encodable, Response: Decodable>(path: String, body: Body) async throws -> Response {
        try await send(path: path, method: "POST", bodyData: JSONEncoder.serviceOps.encode(body), authenticated: false)
    }

    func listTickets(type: TicketKind? = nil, state: String? = nil, limit: Int = 50) async throws -> TicketPage {
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let type {
            queryItems.append(URLQueryItem(name: "type", value: type.rawValue))
        }
        if let state, !state.isEmpty {
            queryItems.append(URLQueryItem(name: "state", value: state))
        }
        return try await send(path: "/api/v1/tickets", queryItems: queryItems)
    }

    func ticket(number: String) async throws -> TicketEnvelope {
        try await send(path: "/api/v1/tickets/\(number.urlPathEncoded)")
    }

    func createIncident(_ draft: IncidentDraft) async throws -> TicketEnvelope {
        try await send(
            path: "/api/v1/incidents",
            method: "POST",
            body: draft,
            idempotencyKey: "ios-incident-\(UUID().uuidString)"
        )
    }

    func updateTicket(number: String, state: String?, priority: String?) async throws -> TicketEnvelope {
        let request = TicketUpdateRequest(state: state, priority: priority)
        return try await send(
            path: "/api/v1/tickets/\(number.urlPathEncoded)",
            method: "PATCH",
            body: request,
            idempotencyKey: "ios-ticket-\(UUID().uuidString)"
        )
    }

    func bootstrap() async throws -> MobileBootstrap {
        let response: MobileBootstrapEnvelope = try await send(path: "/api/v1/mobile/bootstrap")
        return response.data
    }

    func registerPushDevice(token: String, deviceId: String, environment: String) async throws {
        let _: DataEnvelope<PushRegistrationResponse> = try await send(
            path: "/api/v1/mobile/push-devices", method: "POST",
            body: PushDeviceRequest(token: token, deviceId: deviceId, environment: environment),
            idempotencyKey: "push-\(deviceId)-\(token.suffix(12))"
        )
    }

    func unregisterPushDevice(deviceId: String) async throws {
        try await sendNoContent(path: "/api/v1/mobile/push-devices/\(deviceId.urlPathEncoded)", method: "DELETE")
    }

    func notifications() async throws -> [MobileNotification] {
        let response: DataEnvelope<[MobileNotification]> = try await send(path: "/api/v1/mobile/notifications")
        return response.data
    }

    func markNotificationRead(id: Int) async throws {
        let _: DataEnvelope<NotificationReadResponse> = try await send(
            path: "/api/v1/mobile/notifications/\(id)/read", method: "POST", bodyData: Data(), authenticated: true
        )
    }

    func markAllNotificationsRead() async throws {
        try await sendNoContent(path: "/api/v1/mobile/notifications/read-all", method: "POST")
    }

    func approvals() async throws -> [MobileApproval] {
        let response: DataEnvelope<[MobileApproval]> = try await send(path: "/api/v1/mobile/approvals")
        return response.data
    }

    func decideApproval(id: Int, decision: String, comments: String) async throws {
        let _: DataEnvelope<ApprovalDecisionResponse> = try await send(
            path: "/api/v1/mobile/approvals/\(id)/decide", method: "POST",
            body: ApprovalDecisionRequest(decision: decision, comments: comments),
            idempotencyKey: "approval-\(id)-\(UUID().uuidString)"
        )
    }

    func knowledge(query: String = "") async throws -> [KnowledgeArticle] {
        let response: DataEnvelope<[KnowledgeArticle]> = try await send(
            path: "/api/v1/mobile/knowledge", queryItems: query.isEmpty ? [] : [URLQueryItem(name: "q", value: query)]
        )
        return response.data
    }

    func configurationItems(query: String = "") async throws -> [ConfigurationItemSummary] {
        let response: DataEnvelope<[ConfigurationItemSummary]> = try await send(
            path: "/api/v1/mobile/cmdb", queryItems: query.isEmpty ? [] : [URLQueryItem(name: "q", value: query)]
        )
        return response.data
    }

    func comments(number: String) async throws -> [TicketComment] {
        let response: DataEnvelope<[TicketComment]> = try await send(path: "/api/v1/tickets/\(number.urlPathEncoded)/comments")
        return response.data
    }

    func addComment(number: String, body: String) async throws -> TicketComment {
        let response: DataEnvelope<TicketComment> = try await send(
            path: "/api/v1/tickets/\(number.urlPathEncoded)/comments", method: "POST",
            body: CommentRequest(body: body), idempotencyKey: "comment-\(UUID().uuidString)"
        )
        return response.data
    }

    private func send<Response: Decodable>(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        authenticated: Bool = true,
        allowRefresh: Bool = true
    ) async throws -> Response {
        try await send(path: path, method: method, queryItems: queryItems, bodyData: nil, authenticated: authenticated)
    }

    private func send<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body,
        idempotencyKey: String
    ) async throws -> Response {
        let data = try JSONEncoder.serviceOps.encode(body)
        return try await send(
            path: path,
            method: method,
            bodyData: data,
            idempotencyKey: idempotencyKey,
            authenticated: true
        )
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        bodyData: Data?,
        idempotencyKey: String? = nil,
        authenticated: Bool = true,
        allowRefresh: Bool = true
    ) async throws -> Response {
        if authenticated && token.isEmpty {
            throw ServiceOpsAPIError.invalidConfiguration("Your mobile session is unavailable. Sign in again.")
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = joinedPath(baseURL.path, path)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else {
            throw ServiceOpsAPIError.invalidConfiguration("The ServiceOps server URL is invalid.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        request.setValue(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown", forHTTPHeaderField: "X-ServiceOps-App-Version")
        request.setValue(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown", forHTTPHeaderField: "X-ServiceOps-App-Build")
        request.setValue("iOS", forHTTPHeaderField: "X-ServiceOps-Platform")
        request.setValue(Self.deviceModel, forHTTPHeaderField: "X-ServiceOps-Device")
        if authenticated {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceOpsAPIError.transport("ServiceOps returned an invalid response.")
        }
        if httpResponse.statusCode == 401, authenticated, allowRefresh,
           let refreshToken = SecureSessionStore.read(account: "refreshToken") {
            let refreshClient = try ServiceOpsAPIClient(baseURLString: baseURL.absoluteString, token: "", session: session)
            let renewed = try await refreshClient.refresh(refreshToken: refreshToken)
            try SecureSessionStore.save(renewed.accessToken, account: "accessToken")
            try SecureSessionStore.save(renewed.refreshToken, account: "refreshToken")
            token = renewed.accessToken
            return try await send(path: path, method: method, queryItems: queryItems, bodyData: bodyData,
                                  idempotencyKey: idempotencyKey, authenticated: true, allowRefresh: false)
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw ServiceOpsAPIError.server(statusCode: httpResponse.statusCode, message: errorMessage(from: data))
        }
        do {
            return try JSONDecoder.serviceOps.decode(Response.self, from: data)
        } catch {
            throw ServiceOpsAPIError.decoding(error.localizedDescription)
        }
    }

    private func errorMessage(from data: Data) -> String {
        if let apiError = try? JSONDecoder.serviceOps.decode(ServiceOpsErrorResponse.self, from: data) {
            return apiError.description ?? apiError.message ?? "Request failed."
        }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        return "Request failed."
    }

    private func joinedPath(_ basePath: String, _ apiPath: String) -> String {
        let normalizedBase = basePath == "/" ? "" : basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedAPIPath = apiPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "/" + [normalizedBase, normalizedAPIPath].filter { !$0.isEmpty }.joined(separator: "/")
    }

    private static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}

private struct PushRegistrationResponse: Decodable { let deviceId: String; let enabled: Bool }
private struct NotificationReadResponse: Decodable { let id: Int; let read: Bool }
private struct ApprovalDecisionResponse: Decodable { let id: Int; let state: String }


enum ServiceOpsAPIError: LocalizedError {
    case invalidConfiguration(String)
    case transport(String)
    case server(statusCode: Int, message: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .transport(let message), .decoding(let message):
            return message
        case .server(let statusCode, let message):
            return "ServiceOps returned HTTP \(statusCode): \(message)"
        }
    }
}

private struct ServiceOpsErrorResponse: Decodable {
    let message: String?
    let description: String?
}

private extension String {
    var urlPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}

extension JSONDecoder {
    static let serviceOps: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

extension JSONEncoder {
    static let serviceOps: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
}
