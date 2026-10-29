import Foundation
import Security

public struct SessionStore: Sendable {
  public let service: String

  public init(service: String = "dev.entemenubar.EnteMenubar") {
    self.service = service
  }

  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "session",
    ]
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

  public func save(_ session: Data) throws {
    let update = [kSecValueData as String: session]
    let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var request = query
      request[kSecValueData as String] = session
      request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      try check(SecItemAdd(request as CFDictionary, nil))
    } else {
      try check(status)
    }
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
}
