// SPDX-License-Identifier: BUSL-1.1

@preconcurrency import CryptoKit
import Foundation
import Security

protocol LocalBatchKeyProviding: Sendable {
  func localBatchKey(deviceId: String) throws -> SymmetricKey
}

struct KeychainLocalBatchKeyProvider: LocalBatchKeyProviding {
  private let service: String
  private let readKeyData: @Sendable (String, String) throws -> Data?
  private let storeKeyData: @Sendable (String, String, Data) throws -> Bool
  private let generateRandomKeyData: @Sendable () throws -> Data

  init(
    service: String = "dev.evalops.agentd.local-batch-key",
    readKeyData: @escaping @Sendable (String, String) throws -> Data? = Self.readKeyData,
    storeKeyData: @escaping @Sendable (String, String, Data) throws -> Bool = Self.storeKeyData,
    generateRandomKeyData: @escaping @Sendable () throws -> Data = Self.generateRandomKeyData
  ) {
    self.service = service
    self.readKeyData = readKeyData
    self.storeKeyData = storeKeyData
    self.generateRandomKeyData = generateRandomKeyData
  }

  func localBatchKey(deviceId: String) throws -> SymmetricKey {
    if let existing = try readKey(deviceId: deviceId) {
      return SymmetricKey(data: existing)
    }

    let bytes = try generateRandomKeyData()
    if try storeKey(bytes, deviceId: deviceId) {
      return SymmetricKey(data: bytes)
    }

    guard let existing = try readKey(deviceId: deviceId) else {
      throw LocalBatchCryptoError.keychainReadFailed(errSecItemNotFound)
    }
    return SymmetricKey(data: existing)
  }

  private func readKey(deviceId: String) throws -> Data? {
    try readKeyData(service, deviceId)
  }

  private func storeKey(_ key: Data, deviceId: String) throws -> Bool {
    try storeKeyData(service, deviceId, key)
  }

  private static func generateRandomKeyData() throws -> Data {
    var bytes = Data(count: 32)
    let status = bytes.withUnsafeMutableBytes { buffer in
      SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
    }
    guard status == errSecSuccess else {
      throw LocalBatchCryptoError.keyGenerationFailed(status)
    }
    return bytes
  }

  private static func readKeyData(service: String, deviceId: String) throws -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: deviceId,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data = item as? Data else {
      throw LocalBatchCryptoError.keychainReadFailed(status)
    }
    return data
  }

  private static func storeKeyData(service: String, deviceId: String, key: Data) throws -> Bool {
    let attributes: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: deviceId,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: key,
    ]
    let status = SecItemAdd(attributes as CFDictionary, nil)
    switch status {
    case errSecSuccess:
      return true
    case errSecDuplicateItem:
      return false
    default:
      throw LocalBatchCryptoError.keychainWriteFailed(status)
    }
  }
}

struct LocalBatchCryptor: @unchecked Sendable {
  static let encryptedExtension = "agentdbatch"
  private static let magic = Data("AGENTD-BATCH-AESGCM-v1\n".utf8)

  let key: SymmetricKey

  func encrypt(_ plaintext: Data) throws -> Data {
    let sealed = try AES.GCM.seal(plaintext, using: key)
    guard let combined = sealed.combined else {
      throw LocalBatchCryptoError.invalidCiphertext
    }
    return Self.magic + combined
  }

  func decrypt(_ ciphertext: Data) throws -> Data {
    guard ciphertext.starts(with: Self.magic) else {
      throw LocalBatchCryptoError.invalidCiphertext
    }
    let combined = ciphertext.dropFirst(Self.magic.count)
    let box = try AES.GCM.SealedBox(combined: Data(combined))
    return try AES.GCM.open(box, using: key)
  }
}

enum LocalBatchCryptoError: Error, LocalizedError, Equatable {
  case keyGenerationFailed(OSStatus)
  case keychainReadFailed(OSStatus)
  case keychainWriteFailed(OSStatus)
  case invalidCiphertext

  var errorDescription: String? {
    switch self {
    case .keyGenerationFailed(let status):
      return "failed to generate local batch key: \(status)"
    case .keychainReadFailed(let status):
      return "failed to read local batch key from Keychain: \(status)"
    case .keychainWriteFailed(let status):
      return "failed to store local batch key in Keychain: \(status)"
    case .invalidCiphertext:
      return "local batch ciphertext is invalid"
    }
  }
}
