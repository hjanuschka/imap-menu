import Foundation
import Security

struct FolderConfig: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String // Display name for the menubar
    var folderPath: String // IMAP folder path
    var enabled: Bool
    var icon: String // SF Symbol name

    init(id: UUID = UUID(), name: String, folderPath: String, enabled: Bool = true, icon: String = "envelope") {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.enabled = enabled
        self.icon = icon
    }
}

struct IMAPAccount: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String // Display name for the account
    var host: String
    var port: Int
    var username: String
    var password: String // Not persisted, loaded from Keychain
    var useSSL: Bool
    var folders: [FolderConfig]

    init(id: UUID = UUID(), name: String, host: String, port: Int = 993, username: String, password: String = "", useSSL: Bool = true, folders: [FolderConfig] = []) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.useSSL = useSSL
        self.folders = folders
    }
}

// Legacy config for IMAPConnection
struct IMAPConfig {
    var host: String
    var port: Int
    var username: String
    var password: String
    var useSSL: Bool
}

struct AppConfig: Codable {
    var accounts: [IMAPAccount]

    static func load() -> AppConfig {
        guard let data = UserDefaults.standard.data(forKey: "AppConfig"),
              var config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig(accounts: [])
        }

        // Load passwords from Keychain for each account
        for i in 0..<config.accounts.count {
            let account = config.accounts[i]
            config.accounts[i].password = KeychainHelper.getPassword(for: account.username, host: account.host) ?? ""
        }

        return config
    }

    func save() {
        // Save config without passwords to UserDefaults
        var configToSave = self
        for i in 0..<configToSave.accounts.count {
            let account = configToSave.accounts[i]
            // Save password to Keychain if not empty
            if !account.password.isEmpty {
                KeychainHelper.savePassword(account.password, for: account.username, host: account.host)
            }
            configToSave.accounts[i].password = ""
        }

        if let data = try? JSONEncoder().encode(configToSave) {
            UserDefaults.standard.set(data, forKey: "AppConfig")
        }
    }
}

class KeychainHelper {
    static let service = "com.imapmenu.credentials"

    static func savePassword(_ password: String, for username: String, host: String) {
        let account = "\(username)@\(host)"

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        guard let passwordData = password.data(using: .utf8) else { return }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func getPassword(for username: String, host: String) -> String? {
        let account = "\(username)@\(host)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }

        return password
    }

    static func deletePassword(for username: String, host: String) {
        let account = "\(username)@\(host)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }
}
