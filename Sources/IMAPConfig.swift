import Foundation
import Security
import AppKit

// MARK: - Email Filter System

struct EmailFilter: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    
    enum FilterType: String, Codable, CaseIterable {
        case include = "Include"
        case exclude = "Exclude"
    }
    
    enum MatchField: String, Codable, CaseIterable {
        case from = "From"
        case fromName = "From (Name)"
        case fromEmail = "From (Email)"
        case to = "To"
        case subject = "Subject"
        case any = "Any Field"
        
        // Handle legacy field names
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            
            switch rawValue {
            case "From (Name only)":  // Legacy name
                self = .fromName
            case "From (Email only)":  // Legacy name
                self = .fromEmail
            default:
                if let field = MatchField(rawValue: rawValue) {
                    self = field
                } else {
                    self = .from  // Default fallback
                }
            }
        }
    }
    
    enum MatchType: String, Codable, CaseIterable {
        case contains = "Contains"
        case notContains = "Not Contains"
        case equals = "Equals"
        case startsWith = "Starts With"
        case endsWith = "Ends With"
        case regex = "Regex"
    }
    
    var filterType: FilterType
    var field: MatchField
    var matchType: MatchType
    var pattern: String
    var caseSensitive: Bool
    var enabled: Bool
    
    init(id: UUID = UUID(), filterType: FilterType = .include, field: MatchField = .from, matchType: MatchType = .contains, pattern: String = "", caseSensitive: Bool = false, enabled: Bool = true) {
        self.id = id
        self.filterType = filterType
        self.field = field
        self.matchType = matchType
        self.pattern = pattern
        self.caseSensitive = caseSensitive
        self.enabled = enabled
    }
    
    func matches(email: Email) -> Bool {
        guard enabled && !pattern.isEmpty else { return true }
        
        let fieldsToCheck: [String]
        switch field {
        case .from:
            fieldsToCheck = [email.from]
        case .fromName:
            fieldsToCheck = [email.fromName]
        case .fromEmail:
            fieldsToCheck = [email.fromEmail]
        case .to:
            fieldsToCheck = [email.to]
        case .subject:
            fieldsToCheck = [email.subject]
        case .any:
            fieldsToCheck = [email.from, email.fromName, email.fromEmail, email.to, email.subject]
        }
        
        let matchResult = fieldsToCheck.contains { fieldValue in
            matchesPattern(fieldValue)
        }
        
        return matchResult
    }
    
    private func matchesPattern(_ value: String) -> Bool {
        let compareValue = caseSensitive ? value : value.lowercased()
        let comparePattern = caseSensitive ? pattern : pattern.lowercased()
        
        switch matchType {
        case .contains:
            return compareValue.contains(comparePattern)
        case .notContains:
            return !compareValue.contains(comparePattern)
        case .equals:
            return compareValue == comparePattern
        case .startsWith:
            return compareValue.hasPrefix(comparePattern)
        case .endsWith:
            return compareValue.hasSuffix(comparePattern)
        case .regex:
            guard let regex = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : .caseInsensitive) else {
                return false
            }
            let range = NSRange(value.startIndex..., in: value)
            return regex.firstMatch(in: value, options: [], range: range) != nil
        }
    }
}

// MARK: - Filter Group

struct FilterGroup: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var filters: [EmailFilter]
    var logic: GroupLogic  // How filters within this group are combined
    var enabled: Bool
    
    // Server-side IMAP SEARCH (much faster!)
    var useServerSearch: Bool
    var serverSearchQuery: String  // e.g., "OR SUBJECT jxl FROM foolip"
    
    enum GroupLogic: String, Codable, CaseIterable {
        case and = "AND"
        case or = "OR"
    }
    
    init(id: UUID = UUID(), name: String = "New Group", filters: [EmailFilter] = [], logic: GroupLogic = .or, enabled: Bool = true, useServerSearch: Bool = false, serverSearchQuery: String = "") {
        self.id = id
        self.name = name
        self.filters = filters
        self.logic = logic
        self.enabled = enabled
        self.useServerSearch = useServerSearch
        self.serverSearchQuery = serverSearchQuery
    }
    
    // Custom decoder for backward compatibility
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        filters = try container.decodeIfPresent([EmailFilter].self, forKey: .filters) ?? []
        logic = try container.decodeIfPresent(GroupLogic.self, forKey: .logic) ?? .or
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        useServerSearch = try container.decodeIfPresent(Bool.self, forKey: .useServerSearch) ?? false
        serverSearchQuery = try container.decodeIfPresent(String.self, forKey: .serverSearchQuery) ?? ""
    }
    
    /// Build IMAP SEARCH query from filters
    func buildIMAPSearchQuery() -> String? {
        guard useServerSearch else { return nil }
        
        // If custom query provided, use it
        if !serverSearchQuery.isEmpty {
            return serverSearchQuery
        }
        
        // Otherwise build from filters
        let includeFilters = filters.filter { $0.enabled && $0.filterType == .include && !$0.pattern.isEmpty }
        guard !includeFilters.isEmpty else { return nil }
        
        var searchTerms: [String] = []
        for filter in includeFilters {
            let term: String
            switch filter.field {
            case .subject:
                term = "SUBJECT \"\(filter.pattern)\""
            case .from, .fromName, .fromEmail:
                term = "FROM \"\(filter.pattern)\""
            case .to:
                term = "TO \"\(filter.pattern)\""
            case .any:
                term = "TEXT \"\(filter.pattern)\""
            }
            searchTerms.append(term)
        }
        
        if searchTerms.isEmpty { return nil }
        if searchTerms.count == 1 { return searchTerms[0] }
        
        // Combine with OR or AND
        if logic == .or {
            // IMAP OR syntax: OR term1 term2, for multiple: OR term1 OR term2 term3
            var result = searchTerms[0]
            for i in 1..<searchTerms.count {
                result = "OR \(result) \(searchTerms[i])"
            }
            return result
        } else {
            // AND is implicit in IMAP - just space-separate
            return searchTerms.joined(separator: " ")
        }
    }
    
    /// Check if email matches this group's filters
    func matches(email: Email) -> Bool {
        guard enabled else { return true }  // Disabled groups always pass
        
        let activeFilters = filters.filter { $0.enabled && !$0.pattern.isEmpty }
        guard !activeFilters.isEmpty else { return true }  // No filters = pass
        
        let includeFilters = activeFilters.filter { $0.filterType == .include }
        let excludeFilters = activeFilters.filter { $0.filterType == .exclude }
        
        // Exclude filters always use AND logic (if ANY exclude matches, reject)
        for filter in excludeFilters {
            if filter.matches(email: email) {
                debugLog("[Group:\(name)] EXCLUDED by '\(filter.field.rawValue) \(filter.matchType.rawValue) \(filter.pattern)' - from:\(email.from.prefix(30)), fromName:\(email.fromName.prefix(30))")
                return false
            }
        }
        
        // If no include filters, pass (only excludes in this group)
        guard !includeFilters.isEmpty else { 
            return true 
        }
        
        // Apply group logic to include filters
        if logic == .and {
            // ALL include filters must match
            let result = includeFilters.allSatisfy { $0.matches(email: email) }
            if !result {
                debugLog("[Group:\(name)] NOT MATCHED (AND) - subject:\(email.subject.prefix(40))")
            }
            return result
        } else {
            // ANY include filter must match
            let result = includeFilters.contains { $0.matches(email: email) }
            if !result {
                debugLog("[Group:\(name)] NOT MATCHED (OR) - subject:\(email.subject.prefix(40)), from:\(email.from.prefix(30))")
            }
            return result
        }
    }
}

// MARK: - Folder Config

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
    
    enum FilterLogic: String, Codable {
        case and = "AND"
        case or = "OR"
    }

    let id: UUID
    var name: String
    var folderPath: String
    var enabled: Bool
    var icon: String          // SF Symbol name OR URL to image OR local file path
    var iconColor: String
    var iconType: IconType    // .sfSymbol, .url, or .file
    
    enum IconType: String, Codable, CaseIterable {
        case sfSymbol = "sfSymbol"
        case url = "url"
        case file = "file"
    }
    var popoverWidth: PopoverWidth
    
    // Legacy simple filters (kept for backward compatibility)
    var filterSender: String
    var filterSubject: String
    
    // Legacy flat filters (for backward compatibility)
    var filters: [EmailFilter]
    var filterLogic: FilterLogic
    
    // NEW: Filter groups
    var filterGroups: [FilterGroup]
    var groupLogic: FilterLogic  // How groups are combined (AND/OR)
    
    var excludeOwnEmails: Bool
    
    // Hidden folders are not shown in menu bar but available for virtual folders
    var hidden: Bool
    
    // Cache settings
    var lastSeenUID: UInt32
    var cachedEmailCount: Int
    
    // Fetch settings
    var maxEmails: Int
    var daysToFetch: Int

    init(id: UUID = UUID(), name: String, folderPath: String, enabled: Bool = true, icon: String = "envelope", iconColor: String = "", iconType: IconType = .sfSymbol, filterSender: String = "", filterSubject: String = "", popoverWidth: PopoverWidth = .medium, filters: [EmailFilter] = [], filterLogic: FilterLogic = .and, filterGroups: [FilterGroup] = [], groupLogic: FilterLogic = .and, excludeOwnEmails: Bool = false, hidden: Bool = false, lastSeenUID: UInt32 = 0, cachedEmailCount: Int = 0, maxEmails: Int = 100, daysToFetch: Int = 0) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.enabled = enabled
        self.icon = icon
        self.iconColor = iconColor
        self.iconType = iconType
        self.filterSender = filterSender
        self.filterSubject = filterSubject
        self.popoverWidth = popoverWidth
        self.filters = filters
        self.filterLogic = filterLogic
        self.filterGroups = filterGroups
        self.groupLogic = groupLogic
        self.excludeOwnEmails = excludeOwnEmails
        self.hidden = hidden
        self.lastSeenUID = lastSeenUID
        self.cachedEmailCount = cachedEmailCount
        self.maxEmails = maxEmails
        self.daysToFetch = daysToFetch
    }

    // Custom decoding to handle missing fields in old configs - BACKWARD COMPATIBLE
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Required fields from original config
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        folderPath = try container.decode(String.self, forKey: .folderPath)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        icon = try container.decode(String.self, forKey: .icon)
        
        // Optional fields from original config (with defaults)
        iconColor = try container.decodeIfPresent(String.self, forKey: .iconColor) ?? ""
        iconType = try container.decodeIfPresent(IconType.self, forKey: .iconType) ?? .sfSymbol
        filterSender = try container.decodeIfPresent(String.self, forKey: .filterSender) ?? ""
        filterSubject = try container.decodeIfPresent(String.self, forKey: .filterSubject) ?? ""
        popoverWidth = try container.decodeIfPresent(PopoverWidth.self, forKey: .popoverWidth) ?? .medium
        
        // Legacy flat filters
        filters = try container.decodeIfPresent([EmailFilter].self, forKey: .filters) ?? []
        filterLogic = try container.decodeIfPresent(FilterLogic.self, forKey: .filterLogic) ?? .and
        
        // NEW: Filter groups
        filterGroups = try container.decodeIfPresent([FilterGroup].self, forKey: .filterGroups) ?? []
        groupLogic = try container.decodeIfPresent(FilterLogic.self, forKey: .groupLogic) ?? .and
        
        excludeOwnEmails = try container.decodeIfPresent(Bool.self, forKey: .excludeOwnEmails) ?? false
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        lastSeenUID = try container.decodeIfPresent(UInt32.self, forKey: .lastSeenUID) ?? 0
        cachedEmailCount = try container.decodeIfPresent(Int.self, forKey: .cachedEmailCount) ?? 0
        maxEmails = try container.decodeIfPresent(Int.self, forKey: .maxEmails) ?? 100
        daysToFetch = try container.decodeIfPresent(Int.self, forKey: .daysToFetch) ?? 0
        
        // Migrate legacy flat filters to a group if filterGroups is empty but filters exist
        if filterGroups.isEmpty && !filters.isEmpty {
            let legacyGroup = FilterGroup(
                name: "Filters",
                filters: filters,
                logic: filterLogic == .and ? .and : .or
            )
            filterGroups = [legacyGroup]
            print("📦 [FolderConfig] Migrated \(filters.count) legacy filters to group for '\(name)'")
        }
        
        print("📦 [FolderConfig] Decoded '\(name)': groups=\(filterGroups.count), groupLogic=\(groupLogic.rawValue)")
    }

    var nsColor: NSColor {
        if iconColor.isEmpty {
            return .labelColor
        }
        return NSColor(hex: iconColor) ?? .labelColor
    }

    func matchesFilters(email: Email, accountEmail: String = "") -> Bool {
        // First check: exclude own emails if enabled
        if excludeOwnEmails && !accountEmail.isEmpty {
            let emailLower = accountEmail.lowercased()
            if email.from.lowercased().contains(emailLower) {
                return false
            }
        }
        
        // Use filter groups if available
        let activeGroups = filterGroups.filter { $0.enabled }
        
        if !activeGroups.isEmpty {
            if groupLogic == .and {
                // ALL groups must match
                for group in activeGroups {
                    if !group.matches(email: email) {
                        return false
                    }
                }
                return true
            } else {
                // ANY group must match
                return activeGroups.contains { $0.matches(email: email) }
            }
        }
        
        // Fall back to legacy flat filters
        let activeFilters = filters.filter { $0.enabled && !$0.pattern.isEmpty }
        
        if !activeFilters.isEmpty {
            let includeFilters = activeFilters.filter { $0.filterType == .include }
            let excludeFilters = activeFilters.filter { $0.filterType == .exclude }
            
            // Exclude filters first
            for filter in excludeFilters {
                if filter.matches(email: email) {
                    return false
                }
            }
            
            // Include filters
            if !includeFilters.isEmpty {
                if filterLogic == .and {
                    for filter in includeFilters {
                        if !filter.matches(email: email) {
                            return false
                        }
                    }
                } else {
                    let anyMatch = includeFilters.contains { $0.matches(email: email) }
                    if !anyMatch {
                        return false
                    }
                }
            }
            
            return true
        }
        
        // Fall back to legacy simple filters
        if filterSender.isEmpty && filterSubject.isEmpty {
            return true
        }

        var matches = true

        if !filterSender.isEmpty {
            matches = matches && email.from.localizedCaseInsensitiveContains(filterSender)
        }

        if !filterSubject.isEmpty {
            matches = matches && email.subject.localizedCaseInsensitiveContains(filterSubject)
        }

        return matches
    }
}

struct IMAPAccount: Codable, Identifiable, Equatable, Hashable {
    // Account type enum
    enum AccountType: String, Codable, CaseIterable {
        case imap = "IMAP"
        case gmailAppPassword = "Gmail (App Password)"
        case gmailOAuth2 = "Gmail (OAuth2)"
        // Future: case combined = "Combined"
        
        var description: String {
            switch self {
            case .imap: return "Standard IMAP"
            case .gmailAppPassword: return "Gmail with App Password (recommended)"
            case .gmailOAuth2: return "Gmail with OAuth2 (advanced)"
            }
        }
    }
    
    let id: UUID
    var name: String
    var accountType: AccountType
    var host: String
    var port: Int
    var username: String
    var password: String  // For IMAP accounts only
    var useSSL: Bool
    var folders: [FolderConfig]
    
    // OAuth2 settings for Gmail
    var oauth2ClientId: String
    var oauth2ClientSecret: String

    // SMTP settings for sending emails
    var smtpHost: String
    var smtpPort: Int
    var smtpUseSSL: Bool
    var smtpUsername: String  // If empty, uses IMAP username
    var smtpPassword: String  // If empty, uses IMAP password
    var fromEmail: String     // Email address shown in From field (if empty, uses username)
    var fromName: String      // Display name shown in From field (if empty, uses account name)
    var signature: String     // Text signature appended to outgoing emails

    init(id: UUID = UUID(), name: String, accountType: AccountType = .imap, host: String, port: Int = 993, username: String, password: String = "", useSSL: Bool = true, folders: [FolderConfig] = [], oauth2ClientId: String = "", oauth2ClientSecret: String = "", smtpHost: String = "", smtpPort: Int = 587, smtpUseSSL: Bool = true, smtpUsername: String = "", smtpPassword: String = "", fromEmail: String = "", fromName: String = "", signature: String = "") {
        self.id = id
        self.name = name
        self.accountType = accountType
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.useSSL = useSSL
        self.folders = folders
        self.oauth2ClientId = oauth2ClientId
        self.oauth2ClientSecret = oauth2ClientSecret
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpUseSSL = smtpUseSSL
        self.smtpUsername = smtpUsername
        self.smtpPassword = smtpPassword
        self.fromEmail = fromEmail
        self.fromName = fromName
        self.signature = signature
    }

    enum CodingKeys: String, CodingKey {
        case id, name, accountType, host, port, username, password, useSSL, folders
        case oauth2ClientId, oauth2ClientSecret
        case smtpHost, smtpPort, smtpUseSSL, smtpUsername, smtpPassword
        case fromEmail, fromName, signature
    }
    
    // Custom decoder for backward compatibility
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        accountType = try container.decodeIfPresent(AccountType.self, forKey: .accountType) ?? .imap
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        useSSL = try container.decode(Bool.self, forKey: .useSSL)
        folders = try container.decode([FolderConfig].self, forKey: .folders)
        
        // OAuth2 fields
        oauth2ClientId = try container.decodeIfPresent(String.self, forKey: .oauth2ClientId) ?? ""
        oauth2ClientSecret = try container.decodeIfPresent(String.self, forKey: .oauth2ClientSecret) ?? ""

        // SMTP fields with defaults for backward compatibility
        smtpHost = try container.decodeIfPresent(String.self, forKey: .smtpHost) ?? ""
        smtpPort = try container.decodeIfPresent(Int.self, forKey: .smtpPort) ?? 587
        smtpUseSSL = try container.decodeIfPresent(Bool.self, forKey: .smtpUseSSL) ?? true
        smtpUsername = try container.decodeIfPresent(String.self, forKey: .smtpUsername) ?? ""
        smtpPassword = try container.decodeIfPresent(String.self, forKey: .smtpPassword) ?? ""
        fromEmail = try container.decodeIfPresent(String.self, forKey: .fromEmail) ?? ""
        fromName = try container.decodeIfPresent(String.self, forKey: .fromName) ?? ""
        signature = try container.decodeIfPresent(String.self, forKey: .signature) ?? ""
    }

    /// The email address used for sending (From field)
    var emailAddress: String {
        if !fromEmail.isEmpty {
            return fromEmail
        }
        if username.contains("@") {
            return username
        }
        return username
    }
    
    /// The display name used for sending (From field)
    var displayName: String {
        if !fromName.isEmpty {
            return fromName
        }
        return name
    }

    var effectiveSmtpUsername: String {
        smtpUsername.isEmpty ? username : smtpUsername
    }
    
    var effectiveSmtpPassword: String {
        smtpPassword.isEmpty ? password : smtpPassword
    }

    var hasSmtpConfigured: Bool {
        !smtpHost.isEmpty
    }
}

// Legacy config for IMAPConnection
struct IMAPConfig {
    enum AuthMethod {
        case password(String)
        case oauth2(accessToken: String)
    }
    
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    var useSSL: Bool
    
    // Convenience for password auth
    init(host: String, port: Int, username: String, password: String, useSSL: Bool) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = .password(password)
        self.useSSL = useSSL
    }
    
    // For OAuth2 auth
    init(host: String, port: Int, username: String, accessToken: String, useSSL: Bool) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = .oauth2(accessToken: accessToken)
        self.useSSL = useSSL
    }
}

struct AppConfig: Codable {
    var accounts: [IMAPAccount]
    var virtualFolders: [VirtualFolder]
    
    init(accounts: [IMAPAccount] = [], virtualFolders: [VirtualFolder] = []) {
        self.accounts = accounts
        self.virtualFolders = virtualFolders
    }

    static func load() -> AppConfig {
        guard let data = UserDefaults.standard.data(forKey: "AppConfig") else {
            print("⚠️ No AppConfig found in UserDefaults")
            return AppConfig(accounts: [], virtualFolders: [])
        }

        do {
            var config = try JSONDecoder().decode(AppConfig.self, from: data)

            for i in 0..<config.accounts.count {
                let account = config.accounts[i]
                // Load IMAP password
                config.accounts[i].password = KeychainHelper.getPassword(for: account.username, host: account.host) ?? ""
                // Load SMTP password (if configured separately)
                if !account.smtpHost.isEmpty {
                    let smtpUser = account.smtpUsername.isEmpty ? account.username : account.smtpUsername
                    config.accounts[i].smtpPassword = KeychainHelper.getPassword(for: smtpUser, host: account.smtpHost) ?? ""
                }
            }

            return config
        } catch {
            print("❌ Failed to decode AppConfig: \(error)")
            if let jsonString = String(data: data, encoding: .utf8) {
                print("📄 Raw JSON: \(jsonString)")
            }
            return AppConfig(accounts: [], virtualFolders: [])
        }
    }
    
    // Custom decoder for backward compatibility
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decode([IMAPAccount].self, forKey: .accounts)
        virtualFolders = try container.decodeIfPresent([VirtualFolder].self, forKey: .virtualFolders) ?? []
    }
    
    enum CodingKeys: String, CodingKey {
        case accounts
        case virtualFolders
    }

    func save() {
        var configToSave = self
        for i in 0..<configToSave.accounts.count {
            let account = configToSave.accounts[i]
            // Save IMAP password
            if !account.password.isEmpty {
                KeychainHelper.savePassword(account.password, for: account.username, host: account.host)
            }
            // Save SMTP password (if different from IMAP)
            if !account.smtpHost.isEmpty && !account.smtpPassword.isEmpty {
                let smtpUser = account.smtpUsername.isEmpty ? account.username : account.smtpUsername
                KeychainHelper.savePassword(account.smtpPassword, for: smtpUser, host: account.smtpHost)
            }
            configToSave.accounts[i].password = ""
            configToSave.accounts[i].smtpPassword = ""
        }

        if let data = try? JSONEncoder().encode(configToSave) {
            UserDefaults.standard.set(data, forKey: "AppConfig")
        }
    }
    
    mutating func updateLastSeenUID(accountId: UUID, folderId: UUID, uid: UInt32) {
        if let accountIndex = accounts.firstIndex(where: { $0.id == accountId }),
           let folderIndex = accounts[accountIndex].folders.firstIndex(where: { $0.id == folderId }) {
            accounts[accountIndex].folders[folderIndex].lastSeenUID = uid
            save()
        }
    }
}

// MARK: - Virtual Folder (aggregates emails from multiple sources)

struct FolderSource: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var accountId: UUID      // Reference to IMAPAccount
    var folderPath: String   // e.g., "INBOX" or "INBOX/chromium"
    
    init(id: UUID = UUID(), accountId: UUID, folderPath: String) {
        self.id = id
        self.accountId = accountId
        self.folderPath = folderPath
    }
}

struct VirtualFolder: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var icon: String
    var iconType: FolderConfig.IconType
    var iconColor: String
    var sources: [FolderSource]  // Which account/folder combinations to pull from
    var filterGroups: [FilterGroup]  // Filters applied to aggregated emails
    var groupLogic: FolderConfig.FilterLogic
    var enabled: Bool
    var popoverWidth: FolderConfig.PopoverWidth
    var maxEmails: Int  // Max emails to show (0 = unlimited)
    
    init(
        id: UUID = UUID(),
        name: String = "Virtual Folder",
        icon: String = "tray.2",
        iconType: FolderConfig.IconType = .sfSymbol,
        iconColor: String = "#007AFF",
        sources: [FolderSource] = [],
        filterGroups: [FilterGroup] = [],
        groupLogic: FolderConfig.FilterLogic = .or,
        enabled: Bool = true,
        popoverWidth: FolderConfig.PopoverWidth = .large,
        maxEmails: Int = 100
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.iconType = iconType
        self.iconColor = iconColor
        self.sources = sources
        self.filterGroups = filterGroups
        self.groupLogic = groupLogic
        self.enabled = enabled
        self.popoverWidth = popoverWidth
        self.maxEmails = maxEmails
    }
    
    var nsColor: NSColor {
        NSColor(hex: iconColor) ?? .systemBlue
    }
    
    /// Check if an email matches the virtual folder's filters
    func matchesFilters(email: Email) -> Bool {
        let activeGroups = filterGroups.filter { $0.enabled }
        
        if activeGroups.isEmpty {
            return true  // No filters = show all
        }
        
        if groupLogic == .and {
            return activeGroups.allSatisfy { $0.matches(email: email) }
        } else {
            return activeGroups.contains { $0.matches(email: email) }
        }
    }
}

class KeychainHelper {
    static let service = "com.imapmenu.credentials"

    static func savePassword(_ password: String, for username: String, host: String) {
        let account = "\(username)@\(host)"

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

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
    
    // MARK: - Generic Key-Value Storage (for OAuth2 tokens, etc.)
    
    static func save(key: String, value: String) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard let data = value.data(using: .utf8) else { return }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
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
