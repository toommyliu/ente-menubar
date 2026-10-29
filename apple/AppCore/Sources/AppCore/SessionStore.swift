import Foundation
import LocalAuthentication
import Security

public struct SessionStore: Sendable {
  public enum Protection: Sendable {
    case userPresence
    case unprotectedForTests
  }

  public let service: String
  public let protection: Protection

  public init(service: String = "dev.entemenubar.EnteMenubar", protection: Protection) {
    self.service = service
    self.protection = protection
  }

  private var query: [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "session",
    ]
    if protection == .userPresence {
      query[kSecUseDataProtectionKeychain as String] = true
    }
    return query
  }

  public func containsSession() throws -> Bool {
    var request = query
    request[kSecReturnAttributes as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    let context = LAContext()
    context.interactionNotAllowed = true
    request[kSecUseAuthenticationContext as String] = context
    let status = SecItemCopyMatching(request as CFDictionary, nil)
    if status == errSecItemNotFound { return false }
    if status == errSecInteractionNotAllowed { return true }
    try check(status)
    return true
  }

  public func load() throws -> Data? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &value)
    if status == errSecItemNotFound { return nil }
    try check(status)
    guard let data = value as? Data else { throw StorageError.invalidSession }
    return data
  }

  public func deleteLegacyLoginKeychainItem() {
    guard protection == .userPresence else { return }
    SecItemDelete(
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "session",
      ] as CFDictionary)
  }

  public func save(_ session: Data) throws {
    try delete()
    try check(SecItemAdd(addRequest(session) as CFDictionary, nil))
  }

  func addRequest(_ session: Data) throws -> [String: Any] {
    var request = query
    request[kSecValueData as String] = session
    switch protection {
    case .userPresence:
      var error: Unmanaged<CFError>?
      guard
        let access = SecAccessControlCreateWithFlags(
          nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error)
      else {
        throw error?.takeRetainedValue() as Error? ?? StorageError.invalidSession
      }
      request[kSecAttrAccessControl as String] = access
    case .unprotectedForTests:
      request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }
    return request
  }

  public func delete() throws {
    let status = SecItemDelete(query as CFDictionary)
    if status != errSecItemNotFound { try check(status) }
  }

  private func check(_ status: OSStatus) throws {
    guard status == errSecSuccess else { throw StorageError.keychain(status) }
  }
}

enum StorageError: LocalizedError {
  case keychain(OSStatus)
  case invalidSession

  var errorDescription: String? {
    switch self {
    case .keychain(let status): "Unable to access the saved session. Keychain error \(status)."
    case .invalidSession: "The saved session couldn't be read. Sign in again."
    }
  }

  var isCancelled: Bool {
    if case .keychain(let status) = self {
      return status == errSecUserCanceled || status == errSecAuthFailed
    }
    return false
  }
}
