import CryptoKit
import Foundation
import Security
import SwiftUI
import WebKit

/// Stores the user's Cloudflare Access token (the `CF_Authorization` JWT) per server host.
/// The token both passes an Access gate in front of the API and proves the user's
/// Access identity for ServiceOps single sign-on.
enum CloudflareAccessSession {
    private static func account(for host: String) -> String { "cloudflareAccess.\(host.lowercased())" }

    /// The stored token for `host`, or `nil` if there is none or it has expired.
    static func token(for host: String) -> String? {
        guard let token = SecureSessionStore.read(account: account(for: host)) else { return nil }
        if let expiry = expiry(of: token), expiry <= Date().addingTimeInterval(30) {
            clear(for: host)
            return nil
        }
        return token
    }

    static func save(_ token: String, for host: String) {
        try? SecureSessionStore.save(token, account: account(for: host))
    }

    static func clear(for host: String) {
        SecureSessionStore.delete(account: account(for: host))
    }

    /// Reads the `exp` claim without verifying the signature; the server verifies the token.
    private static func expiry(of jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = object["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

/// Presents the Cloudflare Access sign-in page in an isolated web view and returns the
/// `CF_Authorization` token once Access sets it for the ServiceOps host.
struct CloudflareAccessSignInView: View {
    let host: String
    let completion: (String?) -> Void
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            CloudflareAccessWebView(host: host, isLoading: $isLoading) { token in completion(token) }
                .overlay { if isLoading { ProgressView() } }
                .navigationTitle("Cloudflare Access")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { completion(nil) }
                    }
                }
        }
    }
}

private struct CloudflareAccessWebView: UIViewRepresentable {
    let host: String
    @Binding var isLoading: Bool
    let onToken: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Isolated, in-memory storage: nothing from this sign-in outlives the sheet
        // except the Access token the app stores in the Keychain.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        if let url = URL(string: "https://\(host)/") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: CloudflareAccessWebView
        private var delivered = false

        init(_ parent: CloudflareAccessWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            Task { await deliverTokenIfPresent(from: webView) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        private func deliverTokenIfPresent(from webView: WKWebView) async {
            guard !delivered else { return }
            let host = parent.host.lowercased()
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let token = cookies.first { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return cookie.name == "CF_Authorization" && (host == domain || host.hasSuffix("." + domain))
            }?.value
            guard let token, !token.isEmpty else { return }
            delivered = true
            parent.onToken(token)
        }
    }
}

/// RFC 7636 PKCE values for the Keycloak mobile hand-off.
struct PKCEChallenge {
    let verifier: String
    let challenge: String
    let state: String

    init() {
        verifier = Self.randomURLSafeString(byteCount: 32)
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        state = Self.randomURLSafeString(byteCount: 16)
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
