import Foundation
import LocalAuthentication
import Security

enum SecureSessionStore {
    private static let service = "wijesundara.com.ServiceOps.mobile-auth"
    private static let unlockReason = "Unlock your saved ServiceOps mobile session."

    static func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
            throw ServiceOpsAPIError.transport("Unable to protect the mobile session in Keychain.")
        }
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static var hasSession: Bool {
        read(account: "accessToken") != nil || read(account: "refreshToken") != nil
    }

    static func localAuthenticationLabel() -> String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "Unlock with device passcode"
        }

        switch context.biometryType {
        case .faceID:
            return "Unlock with Face ID"
        case .touchID:
            return "Unlock with Touch ID"
        case .opticID:
            return "Unlock with Optic ID"
        default:
            return "Unlock saved session"
        }
    }

    static func unlockAccessToken() async throws -> String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw ServiceOpsAPIError.transport(error?.localizedDescription ?? "Device authentication is unavailable.")
        }

        let authenticated = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: unlockReason)
        guard authenticated, let token = read(account: "accessToken") else {
            throw ServiceOpsAPIError.invalidConfiguration("Your saved ServiceOps session is unavailable. Sign in again.")
        }
        return token
    }

    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service] as CFDictionary)
    }
}
