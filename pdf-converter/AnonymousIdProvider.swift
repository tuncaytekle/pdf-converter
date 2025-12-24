//
//  AnonymousIdProvider.swift
//  pdf-converter
//
//  Created by Tuncay Tekle on 12/24/25.
//


import Foundation
import Security

enum AnonymousIdProvider {
    private static let key = "com.roguewaveapps.pdf-converter.anon_id"

    static func getOrCreate() -> String {
        if let existing = readKeychainString(key: key) { return existing }
        let newId = UUID().uuidString
        _ = saveKeychainString(key: key, value: newId)
        return newId
    }

    private static func readKeychainString(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveKeychainString(key: String, value: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}
