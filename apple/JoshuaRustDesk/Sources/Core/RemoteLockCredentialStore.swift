import Foundation
import LocalAuthentication
import Security

enum RemoteLockCredentialError: LocalizedError {
    case notFound
    case invalidPassword
    case authenticationUnavailable(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "No saved computer login password"
        case .invalidPassword:
            return "The saved computer login password could not be read"
        case .authenticationUnavailable(let message):
            return message
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain error \(status)"
        }
    }
}

/// Stores one remote computer login password per peer, device-only and bound to current biometrics.
final class RemoteLockCredentialStore {
    static let shared = RemoteLockCredentialStore()

    private let service = "com.joshuaji.portico.remote-lock"

    private init() {}

    func authenticate(
        reason: String,
        completion: @escaping (Result<LAContext, Error>) -> Void
    ) {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var policyError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &policyError
        ) else {
            let message = policyError?.localizedDescription
                ?? "Face ID or Touch ID is not available on this device"
            completion(.failure(RemoteLockCredentialError.authenticationUnavailable(message)))
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) {
            success, error in
            DispatchQueue.main.async {
                if success {
                    completion(.success(context))
                } else {
                    completion(.failure(error ?? RemoteLockCredentialError.authenticationUnavailable(
                        "Biometric authentication failed"
                    )))
                }
            }
        }
    }

    func save(password: String, for peerID: String, context: LAContext) throws {
        guard let data = password.data(using: .utf8), !data.isEmpty else {
            throw RemoteLockCredentialError.invalidPassword
        }

        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            &accessError
        ) else {
            throw accessError?.takeRetainedValue()
                ?? RemoteLockCredentialError.authenticationUnavailable(
                    "A device passcode and Face ID or Touch ID are required"
                )
        }

        var deleteQuery = baseQuery(for: peerID)
        deleteQuery[kSecUseAuthenticationContext as String] = context
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw RemoteLockCredentialError.keychain(deleteStatus)
        }

        var addQuery = baseQuery(for: peerID)
        addQuery[kSecAttrAccessControl as String] = accessControl
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw RemoteLockCredentialError.keychain(addStatus)
        }
    }

    func retrieve(
        for peerID: String,
        reason: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var query = baseQuery(for: peerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseOperationPrompt as String] = reason

        DispatchQueue.global(qos: .userInitiated).async {
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            let result: Result<String, Error>

            if status == errSecItemNotFound {
                result = .failure(RemoteLockCredentialError.notFound)
            } else if status != errSecSuccess {
                result = .failure(RemoteLockCredentialError.keychain(status))
            } else if let data = item as? Data,
                      let password = String(data: data, encoding: .utf8),
                      !password.isEmpty {
                result = .success(password)
            } else {
                result = .failure(RemoteLockCredentialError.invalidPassword)
            }

            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func remove(for peerID: String) {
        SecItemDelete(baseQuery(for: peerID) as CFDictionary)
    }

    private func baseQuery(for peerID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: peerID,
        ]
    }
}
