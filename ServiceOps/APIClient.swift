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

    /// The sign-in methods this server enables, or `nil` for servers that predate
    /// method discovery (the endpoint is missing or still requires authentication).
    func authMethods() async throws -> MobileAuthMethods? {
        do {
            let response: DataEnvelope<MobileAuthMethods> = try await send(path: "/api/v1/auth/mobile/methods", authenticated: false)
            return response.data
        } catch let error as ServiceOpsAPIError where [401, 404, 405].contains(error.statusCode ?? 0) {
            return nil
        }
    }

    /// Exchanges the user's Cloudflare Access identity for a ServiceOps mobile session,
    /// matching the web app's Access single sign-on.
    func loginWithCloudflareAccess(assertion: String, mfaCode: String?) async throws -> MobileAuthResponse {
        let data = try await perform(
            path: "/api/v1/auth/mobile/cloudflare-access", method: "POST", queryItems: [],
            bodyData: JSONEncoder.serviceOps.encode(MFACodeRequest(mfaCode: mfaCode)),
            idempotencyKey: nil, authenticated: false, allowRefresh: false,
            extraHeaders: ["Cf-Access-Jwt-Assertion": assertion]
        )
        return try decode(data)
    }

    func keycloakStartURL(codeChallenge: String, state: String) throws -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = joinedPath(baseURL.path, "/auth/keycloak/mobile/start")
        components?.queryItems = [URLQueryItem(name: "code_challenge", value: codeChallenge),
                                  URLQueryItem(name: "state", value: state)]
        guard let url = components?.url else { throw ServiceOpsAPIError.invalidConfiguration("The ServiceOps server URL is invalid.") }
        return url
    }

    func exchangeKeycloakCode(_ code: String, verifier: String) async throws -> MobileAuthResponse {
        try await sendUnauthenticated(
            path: "/api/v1/auth/mobile/keycloak/exchange",
            body: KeycloakExchangeRequest(code: code, codeVerifier: verifier)
        )
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

    /// Sends an authenticated request whose success response has no body (HTTP 204),
    /// sharing the same headers, token refresh, and error handling as `send`.
    private func sendNoContent(path: String, method: String) async throws {
        _ = try await perform(path: path, method: method, queryItems: [], bodyData: nil,
                              idempotencyKey: nil, authenticated: true, allowRefresh: true)
    }

    private func sendUnauthenticated<Body: Encodable, Response: Decodable>(path: String, body: Body) async throws -> Response {
        try await send(path: path, method: "POST", bodyData: JSONEncoder.serviceOps.encode(body), authenticated: false)
    }

    func listTickets(type: TicketKind? = nil, state: String? = nil, limit: Int = 50, cursor: Int? = nil) async throws -> TicketPage {
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: String(cursor)))
        }
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

    func rack(id: Int) async throws -> RackViewEnvelope {
        try await send(path: "/api/v1/mobile/racks/\(id)")
    }

    /// Rack-mounted CIs linked to a ticket, primary CI first, as the web ticket page shows them.
    /// Returns `nil` on servers that don't publish rack placements yet.
    func ticketRackPlacements(number: String) async throws -> TicketRackPlacementsEnvelope? {
        do {
            return try await send(path: "/api/v1/mobile/tickets/\(number.urlPathEncoded)/rack-placements")
        } catch let error as ServiceOpsAPIError where error.statusCode == 404 && error.serverCode == nil {
            // A 404 for this ticket comes from the route itself on older servers; a missing
            // ticket would already have failed loading the ticket screen.
            return nil
        }
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

    func attachments(number: String) async throws -> [TicketAttachment] {
        let response: DataEnvelope<[TicketAttachment]> = try await send(path: "/api/v1/tickets/\(number.urlPathEncoded)/attachments")
        return response.data
    }

    /// Downloads an attachment into a temporary file named after the original so
    /// Quick Look can pick the right previewer.
    func downloadAttachment(number: String, attachment: TicketAttachment) async throws -> URL {
        let data = try await perform(
            path: "/api/v1/tickets/\(number.urlPathEncoded)/attachments/\(attachment.id)/download",
            method: "GET", queryItems: [], bodyData: nil, idempotencyKey: nil,
            authenticated: true, allowRefresh: true
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachments/\(attachment.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = attachment.fileName.replacingOccurrences(of: "/", with: "_")
        let fileURL = directory.appendingPathComponent(safeName.isEmpty ? "attachment" : safeName)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        return fileURL
    }

    func changeTasks(number: String) async throws -> [ChangeTask] {
        let response: DataEnvelope<[ChangeTask]> = try await send(path: "/api/v1/tickets/\(number.urlPathEncoded)/ctasks")
        return response.data
    }

    func updateChangeTask(number: String, task: String, state: String?, note: String?) async throws -> ChangeTask {
        let response: DataEnvelope<ChangeTask> = try await send(
            path: "/api/v1/tickets/\(number.urlPathEncoded)/ctasks/\(task.urlPathEncoded)", method: "PATCH",
            body: ChangeTaskUpdateRequest(state: state, appendWorkNotes: note),
            idempotencyKey: "ctask-\(UUID().uuidString)"
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
        let data = try await perform(path: path, method: method, queryItems: queryItems, bodyData: bodyData,
                                     idempotencyKey: idempotencyKey, authenticated: authenticated,
                                     allowRefresh: allowRefresh)
        return try decode(data)
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try JSONDecoder.serviceOps.decode(Response.self, from: data)
        } catch {
            throw ServiceOpsAPIError.decoding(error.localizedDescription)
        }
    }

    /// Performs the request and returns the raw body of a 2xx response. An expired
    /// access token (HTTP 401) is renewed once with the stored refresh token.
    private func perform(
        path: String,
        method: String,
        queryItems: [URLQueryItem],
        bodyData: Data?,
        idempotencyKey: String?,
        authenticated: Bool,
        allowRefresh: Bool,
        extraHeaders: [String: String] = [:]
    ) async throws -> Data {
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
        // Lets requests through a Cloudflare Access gate when the user signed in to
        // Access in the app; harmless when Access bypasses the API.
        if let host = baseURL.host, let accessToken = CloudflareAccessSession.token(for: host) {
            request.setValue(accessToken, forHTTPHeaderField: "cf-access-token")
        }
        for (field, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }

        let (data, response) = try await session.data(for: request, delegate: SameHostRedirectGuard())
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceOpsAPIError.transport("ServiceOps returned an invalid response.")
        }
        if 300..<400 ~= httpResponse.statusCode {
            if isCloudflareAccessChallenge(httpResponse), let host = baseURL.host {
                // A stored Access token that no longer works has expired or been revoked.
                CloudflareAccessSession.clear(for: host)
                throw ServiceOpsAPIError.accessRequired(host: host)
            }
            throw ServiceOpsAPIError.transport(redirectMessage(for: httpResponse))
        }
        if httpResponse.statusCode == 401, authenticated, allowRefresh,
           let refreshToken = SecureSessionStore.read(account: "refreshToken") {
            let refreshClient = try ServiceOpsAPIClient(baseURLString: baseURL.absoluteString, token: "", session: session)
            let renewed = try await refreshClient.refresh(refreshToken: refreshToken)
            try SecureSessionStore.save(renewed.accessToken, account: "accessToken")
            try SecureSessionStore.save(renewed.refreshToken, account: "refreshToken")
            token = renewed.accessToken
            return try await perform(path: path, method: method, queryItems: queryItems, bodyData: bodyData,
                                     idempotencyKey: idempotencyKey, authenticated: true, allowRefresh: false,
                                     extraHeaders: extraHeaders)
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            let apiError = try? JSONDecoder.serviceOps.decode(ServiceOpsErrorResponse.self, from: data)
            throw ServiceOpsAPIError.server(
                statusCode: httpResponse.statusCode, message: errorMessage(from: data, decoded: apiError),
                code: apiError?.error?.code
            )
        }
        return data
    }

    private func errorMessage(from data: Data, decoded apiError: ServiceOpsErrorResponse?) -> String {
        if let message = apiError?.error?.detail ?? apiError?.error?.title ?? apiError?.description ?? apiError?.message {
            return message
        }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        return "Request failed."
    }

    private func isCloudflareAccessChallenge(_ response: HTTPURLResponse) -> Bool {
        let location = response.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0)?.host } ?? ""
        return location.hasSuffix("cloudflareaccess.com")
            || response.value(forHTTPHeaderField: "WWW-Authenticate")?.hasPrefix("Cloudflare-Access") == true
    }

    private func redirectMessage(for response: HTTPURLResponse) -> String {
        let location = response.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0)?.host } ?? "another site"
        return "The server redirected the request to \(location) instead of answering. Check the ServiceOps server URL."
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

/// Refuses redirects to a different host so bearer tokens and request bodies never
/// follow a redirect off the ServiceOps server (for example to an SSO gateway);
/// the 3xx response is returned to the caller instead.
private nonisolated final class SameHostRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.host == task.originalRequest?.url?.host ? request : nil)
    }
}

private struct PushRegistrationResponse: Decodable { let deviceId: String; let enabled: Bool }
private struct NotificationReadResponse: Decodable { let id: Int; let read: Bool }
private struct ApprovalDecisionResponse: Decodable { let id: Int; let state: String }


enum ServiceOpsAPIError: LocalizedError {
    case invalidConfiguration(String)
    case transport(String)
    /// `code` is the server's machine-readable reason (for example `mfa_required`), when it sends one.
    case server(statusCode: Int, message: String, code: String?)
    case decoding(String)
    /// Cloudflare Access intercepted the request; the user must sign in to Access first.
    case accessRequired(host: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .transport(let message), .decoding(let message):
            return message
        case .server(let statusCode, let message, _):
            return "ServiceOps returned HTTP \(statusCode): \(message)"
        case .accessRequired(let host):
            return "\(host) is protected by Cloudflare Access. Sign in to Access to continue."
        }
    }

    var serverCode: String? {
        if case .server(_, _, let code) = self { return code }
        return nil
    }

    var statusCode: Int? {
        if case .server(let status, _, _) = self { return status }
        return nil
    }

    /// The server's own message without the HTTP status prefix.
    var serverMessage: String? {
        if case .server(_, let message, _) = self { return message }
        return nil
    }
}

/// ServiceOps returns `{"error": {"status", "title", "detail", "request_id", "code"?}}`;
/// the flat `message`/`description` keys are kept for proxies and older servers.
private struct ServiceOpsErrorResponse: Decodable {
    struct Detail: Decodable {
        let title: String?
        let detail: String?
        let code: String?
    }

    let error: Detail?
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
