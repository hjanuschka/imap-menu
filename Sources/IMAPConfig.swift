import Foundation
import Security
import AppKit

struct FolderConfig: Codable, Identifiable, Equatable, Hashable {
    enum PopoverWidth: String, Codable {
        case small = "small"
        case medium = "medium"
        case large = "large"

        var size: NSSize {
            switch self {
            case .small: return NSSize(width: 350, height: 500)
            case .medium: return NSSize(width: 450, height: 550)
            case .large: return NSSize(width: 600, height: 650)
            }
        }
    }

    let id: UUID
    var name: String // Display name for the menubar
    var folderPath: String // IMAP folder path
    var enabled: Bool
    var icon: String // SF Symbol name
    var iconColor: String // Hex color for icon (e.g., "#FF0000")
    var filterSender: String // Filter emails by sender (contains, case-insensitive)
    var filterSubject: String // Filter emails by subject (contains, case-insensitive)
    var popoverWidth: PopoverWidth // Popover size

    init(id: UUID = UUID(), name: String, folderPath: String, enabled: Bool = true, icon: String = "envelope", iconColor: String = "", filterSender: String = "", filterSubject: String = "", popoverWidth: PopoverWidth = .medium) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.enabled = enabled
        self.icon = icon
        self.iconColor = iconColor
        self.filterSender = filterSender
        self.filterSubject = filterSubject
        self.popoverWidth = popoverWidth
    }

    // Custom decoding to handle missing popoverWidth in old configs
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        folderPath = try container.decode(String.self, forKey: .folderPath)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        icon = try container.decode(String.self, forKey: .icon)
        iconColor = try container.decodeIfPresent(String.self, forKey: .iconColor) ?? ""
        filterSender = try container.decodeIfPresent(String.self, forKey: .filterSender) ?? ""
        filterSubject = try container.decodeIfPresent(String.self, forKey: .filterSubject) ?? ""
        popoverWidth = try container.decodeIfPresent(PopoverWidth.self, forKey: .popoverWidth) ?? .medium
    }

    var nsColor: NSColor {
        if iconColor.isEmpty {
            return .labelColor
        }
        return NSColor(hex: iconColor) ?? .labelColor
    }

    func matchesFilters(email: Email) -> Bool {
        // If no filters set, show all emails
        if filterSender.isEmpty && filterSubject.isEmpty {
            return true
        }

        var matches = true

        // Check sender filter
        if !filterSender.isEmpty {
            matches = matches && email.from.localizedCaseInsensitiveContains(filterSender)
        }

        // Check subject filter
        if !filterSubject.isEmpty {
            matches = matches && email.subject.localizedCaseInsensitiveContains(filterSubject)
        }

        return matches
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
        guard let data = UserDefaults.standard.data(forKey: "AppConfig") else {
            print("⚠️ No AppConfig found in UserDefaults")
            return AppConfig(accounts: [])
        }

        // Try to decode, with detailed error logging
        do {
            var config = try JSONDecoder().decode(AppConfig.self, from: data)

            // Load passwords from Keychain for each account
            for i in 0..<config.accounts.count {
                let account = config.accounts[i]
                config.accounts[i].password = KeychainHelper.getPassword(for: account.username, host: account.host) ?? ""

                // Debug: log folder icons
                print("🔍 [AppConfig.load] Account '\(account.name)' folders:")
                for folder in account.folders {
                    print("    - '\(folder.name)': icon='\(folder.icon)', color='\(folder.iconColor)', width=\(folder.popoverWidth.rawValue)")
                }
            }

            return config
        } catch {
            print("❌ Failed to decode AppConfig: \(error)")
            if let jsonString = String(data: data, encoding: .utf8) {
                print("📄 Raw JSON: \(jsonString)")
            }
            return AppConfig(accounts: [])
        }
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

extension NSColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let length = hexSanitized.count
        let r, g, b, a: CGFloat

        if length == 6 {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0
            a = 1.0
        } else if length == 8 {
            r = CGFloat((rgb & 0xFF000000) >> 24) / 255.0
            g = CGFloat((rgb & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((rgb & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(rgb & 0x000000FF) / 255.0
        } else {
            return nil
        }

        self.init(red: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        guard let components = cgColor.components, components.count >= 3 else {
            return "#000000"
        }
        let r = Int(components[0] * 255.0)
        let g = Int(components[1] * 255.0)
        let b = Int(components[2] * 255.0)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
