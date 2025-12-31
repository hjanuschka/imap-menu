import Foundation
import Combine

struct Email: Identifiable, Hashable {
    let id: String
    let uid: UInt32
    let subject: String
    let from: String           // Full "Name <email>" or just display name
    let fromEmail: String      // Just the email address (extracted)
    let fromName: String       // Just the display name (extracted)
    let to: String
    let date: Date
    let preview: String
    let body: String
    let contentType: String
    let boundary: String
    var isRead: Bool

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Email, rhs: Email) -> Bool {
        lhs.id == rhs.id
    }

    // Get HTML representation of email body
    func getHTMLBody() -> String {
        let mimeParser = MIMEParser(body: body, contentType: contentType, boundary: boundary)
        return mimeParser.getHTMLContent()
    }
    
    // Parse "Display Name <email@example.com>" into components
    static func parseFromField(_ from: String) -> (name: String, email: String) {
        let trimmed = from.trimmingCharacters(in: .whitespaces)
        
        // Check for "Name <email>" format
        if let angleStart = trimmed.firstIndex(of: "<"),
           let angleEnd = trimmed.firstIndex(of: ">") {
            let name = String(trimmed[..<angleStart])
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\"", with: "")
            let email = String(trimmed[trimmed.index(after: angleStart)..<angleEnd])
                .trimmingCharacters(in: .whitespaces)
            return (name.isEmpty ? email : name, email)
        }
        
        // Just an email address or name
        if trimmed.contains("@") {
            return (trimmed, trimmed)
        }
        
        return (trimmed, "")
    }
}

// MARK: - Email Cache for Speed

class EmailCache {
    static let shared = EmailCache()
    
    private var cache: [String: [Email]] = [:] // folder path -> emails
    private var lastFetchTime: [String: Date] = [:]
    private var highestUID: [String: UInt32] = [:]
    
    private let cacheQueue = DispatchQueue(label: "com.imapmenu.cache", attributes: .concurrent)
    
    func getCachedEmails(for folderPath: String) -> [Email]? {
        cacheQueue.sync {
            return cache[folderPath]
        }
    }
    
    func setCachedEmails(_ emails: [Email], for folderPath: String) {
        cacheQueue.async(flags: .barrier) {
            self.cache[folderPath] = emails
            self.lastFetchTime[folderPath] = Date()
            if let maxUID = emails.map({ $0.uid }).max() {
                self.highestUID[folderPath] = maxUID
            }
        }
    }
    
    func getHighestUID(for folderPath: String) -> UInt32 {
        cacheQueue.sync {
            return highestUID[folderPath] ?? 0
        }
    }
    
    func mergeNewEmails(_ newEmails: [Email], for folderPath: String, maxEmails: Int = 0) -> [Email] {
        cacheQueue.sync {
            var existing = cache[folderPath] ?? []
            let existingUIDs = Set(existing.map { $0.uid })
            
            for email in newEmails where !existingUIDs.contains(email.uid) {
                existing.append(email)
            }
            
            // Sort by date descending
            existing.sort { $0.date > $1.date }
            
            // Limit only if maxEmails > 0
            if maxEmails > 0 && existing.count > maxEmails {
                existing = Array(existing.prefix(maxEmails))
            }
            
            return existing
        }
    }
    
    func updateEmail(_ email: Email, for folderPath: String) {
        cacheQueue.async(flags: .barrier) {
            if var emails = self.cache[folderPath],
               let index = emails.firstIndex(where: { $0.id == email.id }) {
                emails[index] = email
                self.cache[folderPath] = emails
            }
        }
    }
    
    func removeEmail(uid: UInt32, from folderPath: String) {
        cacheQueue.async(flags: .barrier) {
            self.cache[folderPath]?.removeAll { $0.uid == uid }
        }
    }
    
    func invalidate(folderPath: String) {
        cacheQueue.async(flags: .barrier) {
            self.cache.removeValue(forKey: folderPath)
            self.lastFetchTime.removeValue(forKey: folderPath)
            self.highestUID.removeValue(forKey: folderPath)
        }
    }
    
    func isCacheValid(for folderPath: String, maxAge: TimeInterval = 300) -> Bool {
        cacheQueue.sync {
            guard let lastFetch = lastFetchTime[folderPath] else { return false }
            return Date().timeIntervalSince(lastFetch) < maxAge
        }
    }
}

// MARK: - Connection Pool for Speed

class IMAPConnectionPool {
    static let shared = IMAPConnectionPool()

    private var connections: [String: IMAPConnection] = [:] // host:user:folder -> connection
    private var inUse: Set<String> = [] // Track which connections are currently in use
    private var lastUsed: [String: Date] = [:]
    private let poolQueue = DispatchQueue(label: "com.imapmenu.pool")
    private var cleanupTimer: Timer?

    init() {
        // Cleanup idle connections every 2 minutes
        DispatchQueue.main.async {
            self.cleanupTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
                self?.cleanupIdleConnections()
            }
        }
    }

    private func connectionKey(for config: IMAPConfig, folder: String) -> String {
        return "\(config.host):\(config.username):\(folder)"
    }

    func getConnection(for config: IMAPConfig, folder: String) throws -> IMAPConnection {
        let key = connectionKey(for: config, folder: folder)

        return try poolQueue.sync {
            // Check if connection exists and is not in use
            if let existing = connections[key], !inUse.contains(key) {
                if existing.isConnected {
                    inUse.insert(key)
                    lastUsed[key] = Date()
                    print("[ConnectionPool] Reusing connection for \(key)")
                    return existing
                } else {
                    // Remove dead connection
                    connections.removeValue(forKey: key)
                }
            }

            // If connection is in use, create a new temporary one
            if inUse.contains(key) {
                print("[ConnectionPool] Connection in use, creating temporary for \(key)")
                let tempConnection = IMAPConnection(config: config)
                try tempConnection.connect()
                return tempConnection
            }

            // Create new connection
            print("[ConnectionPool] Creating new connection for \(key)")
            let connection = IMAPConnection(config: config)
            try connection.connect()

            connections[key] = connection
            inUse.insert(key)
            lastUsed[key] = Date()

            return connection
        }
    }

    func returnConnection(_ connection: IMAPConnection, for config: IMAPConfig, folder: String) {
        let key = connectionKey(for: config, folder: folder)
        poolQueue.sync {
            inUse.remove(key)
            lastUsed[key] = Date()
        }
    }

    func invalidateConnection(for config: IMAPConfig, folder: String) {
        let key = connectionKey(for: config, folder: folder)
        poolQueue.sync {
            if let conn = connections.removeValue(forKey: key) {
                conn.disconnect()
            }
            inUse.remove(key)
            lastUsed.removeValue(forKey: key)
        }
    }

    private func cleanupIdleConnections() {
        let maxIdleTime: TimeInterval = 300 // 5 minutes
        let now = Date()

        poolQueue.sync {
            for (key, lastUse) in lastUsed {
                // Only cleanup if not in use and idle for too long
                if !inUse.contains(key) && now.timeIntervalSince(lastUse) > maxIdleTime {
                    print("[ConnectionPool] Closing idle connection: \(key)")
                    connections[key]?.disconnect()
                    connections.removeValue(forKey: key)
                    lastUsed.removeValue(forKey: key)
                }
            }
        }
    }
}

// MARK: - MIME Parser

class MIMEParser {
    let body: String
    let contentType: String
    let boundary: String

    init(body: String, contentType: String, boundary: String) {
        self.body = body
        self.contentType = contentType
        self.boundary = boundary
    }

    func getHTMLContent() -> String {
        var effectiveBoundary = boundary
        if effectiveBoundary.isEmpty {
            effectiveBoundary = findBoundaryInBody()
        }

        if !effectiveBoundary.isEmpty && body.contains("--" + effectiveBoundary) {
            let result = parseMultipart(boundary: effectiveBoundary)
            if !result.isEmpty {
                return result
            }
        }

        if contentType.lowercased().contains("text/html") {
            let decoded = decodeContent(body, headers: "Content-Type: \(contentType)")
            return decoded
        } else {
            let decoded = decodeContent(body, headers: "Content-Type: \(contentType)")
            let wrapped = wrapPlainText(decoded)
            return wrapped
        }
    }

    private func findBoundaryInBody() -> String {
        let pattern = #"--([a-zA-Z0-9_=\-]+)\r?\n"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return ""
        }

        let range = NSRange(body.startIndex..., in: body)
        if let match = regex.firstMatch(in: body, options: [], range: range),
           let boundaryRange = Range(match.range(at: 1), in: body) {
            return String(body[boundaryRange])
        }
        return ""
    }

    private func parseMultipart(boundary: String) -> String {
        let separator = "--" + boundary
        let parts = body.components(separatedBy: separator)
        var htmlContent: String?
        var textContent: String?

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "--" || trimmed.hasPrefix("--") { continue }

            var headerEnd: Range<String.Index>?
            if let range = part.range(of: "\r\n\r\n") {
                headerEnd = range
            } else if let range = part.range(of: "\n\n") {
                headerEnd = range
            }

            guard let hEnd = headerEnd else { continue }

            let headers = String(part[..<hEnd.lowerBound])
            var content = String(part[hEnd.upperBound...])

            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.hasSuffix("--") {
                content = String(content.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let headersLower = headers.lowercased()

            if headersLower.contains("multipart/") {
                if let nestedBoundary = extractBoundary(from: headers) {
                    let nestedParser = MIMEParser(body: content, contentType: headers, boundary: nestedBoundary)
                    let nested = nestedParser.getHTMLContent()
                    if !nested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                       !nested.contains("<!DOCTYPE html>") || nested.count > 100 {
                        return nested
                    }
                }
            }

            if headersLower.contains("text/html") {
                let decoded = decodeContent(content, headers: headers)
                if !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    htmlContent = decoded
                }
            } else if headersLower.contains("text/plain") {
                let decoded = decodeContent(content, headers: headers)
                if !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    textContent = decoded
                }
            }
        }

        if let html = htmlContent, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ensureHTMLWrapper(html)
        }
        if let text = textContent, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return wrapPlainText(text)
        }

        return wrapPlainText(extractReadableText(from: body))
    }

    private func extractBoundary(from headers: String) -> String? {
        let patterns = [
            #"boundary="([^"]+)""#,
            #"boundary=([^\s;]+)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }

            let range = NSRange(headers.startIndex..., in: headers)
            if let match = regex.firstMatch(in: headers, options: [], range: range),
               let boundaryRange = Range(match.range(at: 1), in: headers) {
                return String(headers[boundaryRange])
            }
        }
        return nil
    }

    private func decodeContent(_ content: String, headers: String) -> String {
        var result = content
        let headersLower = headers.lowercased()

        if headersLower.contains("quoted-printable") {
            result = decodeQuotedPrintable(result)
        } else if headersLower.contains("base64") {
            result = decodeBase64(result)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeQuotedPrintable(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "=\r\n", with: "")
        result = result.replacingOccurrences(of: "=\n", with: "")

        var decoded = Data()
        var i = result.startIndex

        while i < result.endIndex {
            let char = result[i]
            if char == "=" {
                let nextIdx = result.index(after: i)
                if nextIdx < result.endIndex,
                   let endIdx = result.index(nextIdx, offsetBy: 2, limitedBy: result.endIndex) {
                    let hex = String(result[nextIdx..<endIdx])
                    if let byte = UInt8(hex, radix: 16) {
                        decoded.append(byte)
                        i = endIdx
                        continue
                    }
                }
                decoded.append(UInt8(ascii: "="))
            } else if let ascii = char.asciiValue {
                decoded.append(ascii)
            } else {
                for byte in String(char).utf8 {
                    decoded.append(byte)
                }
            }
            i = result.index(after: i)
        }

        return String(data: decoded, encoding: .utf8) ?? String(data: decoded, encoding: .isoLatin1) ?? result
    }

    private func decodeBase64(_ string: String) -> String {
        let cleaned = string
            .replacingOccurrences(of: "\r\n", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")

        guard let data = Data(base64Encoded: cleaned) else {
            return string
        }

        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? string
    }

    private func extractReadableText(from body: String) -> String {
        var lines: [String] = []
        var inContent = false

        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("--") && trimmed.count > 20 {
                inContent = false
                continue
            }

            if trimmed.lowercased().hasPrefix("content-") ||
               trimmed.lowercased().hasPrefix("mime-") {
                continue
            }

            if trimmed.isEmpty && !inContent {
                inContent = true
                continue
            }

            if inContent && !trimmed.isEmpty {
                lines.append(line)
            }
        }

        let text = lines.joined(separator: "\n")
        return decodeQuotedPrintable(text)
    }

    private func ensureHTMLWrapper(_ html: String) -> String {
        if html.lowercased().contains("<html") {
            return html
        }
        if html.lowercased().contains("<body") {
            return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head>\(html)</html>"
        }
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>\(html)</body></html>"
    }

    private func wrapPlainText(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    font-size: 13px;
                    line-height: 1.6;
                    padding: 16px;
                    color: #333;
                    background: white;
                    margin: 0;
                }
            </style>
        </head>
        <body>\(escaped)</body>
        </html>
        """
    }

    static func createPreview(from body: String, boundary: String) -> String {
        let parser = MIMEParser(body: body, contentType: "", boundary: boundary)

        var effectiveBoundary = boundary
        if effectiveBoundary.isEmpty {
            effectiveBoundary = parser.findBoundaryInBody()
        }

        var text = ""

        if !effectiveBoundary.isEmpty {
            let parts = body.components(separatedBy: "--" + effectiveBoundary)
            for part in parts {
                if let headerEnd = part.range(of: "\r\n\r\n") ?? part.range(of: "\n\n") {
                    let headers = String(part[..<headerEnd.lowerBound]).lowercased()
                    if headers.contains("text/plain") {
                        let content = String(part[headerEnd.upperBound...])
                        text = parser.decodeContent(content, headers: headers)
                        break
                    }
                }
            }
        }

        if text.isEmpty {
            text = parser.extractReadableText(from: body)
        }

        text = text
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if text.count > 150 {
            text = String(text.prefix(150)) + "..."
        }

        return text
    }
}

// MARK: - Email Manager

class EmailManager: ObservableObject {
    @Published var emails: [Email] = []
    @Published var isConnected = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var unreadCount: Int = 0
    @Published var secondsUntilRefresh: Int = 60
    @Published var lastFetchDuration: TimeInterval = 0

    private var imapConnection: IMAPConnection?
    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var notificationObserver: Any?
    private let refreshInterval: Int = 60
    
    private let cache = EmailCache.shared
    private let connectionPool = IMAPConnectionPool.shared

    let account: IMAPAccount
    let folderConfig: FolderConfig

    init(account: IMAPAccount, folderConfig: FolderConfig) {
        self.account = account
        self.folderConfig = folderConfig

        notificationObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("RefreshEmails"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.fetchEmails(forceFullRefresh: true)
        }
    }

    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        stopFetching()
    }

    func startFetching() {
        // Try to show cached emails immediately
        if let cached = cache.getCachedEmails(for: cacheKey) {
            let filtered = applyFilters(to: cached)
            DispatchQueue.main.async {
                self.emails = filtered
                self.unreadCount = filtered.filter { !$0.isRead }.count
                self.isConnected = true
            }
        }
        
        fetchEmails(forceFullRefresh: false)
        startTimers()
    }
    
    private var cacheKey: String {
        return "\(account.id):\(folderConfig.folderPath)"
    }

    private func startTimers() {
        stopTimers()

        secondsUntilRefresh = refreshInterval

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if self.secondsUntilRefresh > 0 {
                    self.secondsUntilRefresh -= 1
                }
            }
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: Double(refreshInterval), repeats: true) { [weak self] _ in
            self?.fetchEmails(forceFullRefresh: false)
            DispatchQueue.main.async {
                self?.secondsUntilRefresh = self?.refreshInterval ?? 60
            }
        }
    }

    private func stopTimers() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    func stopFetching() {
        stopTimers()
        // Don't disconnect - let connection pool manage it
    }

    func fetchEmails(forceFullRefresh: Bool = false) {
        guard !account.host.isEmpty else {
            DispatchQueue.main.async {
                self.errorMessage = "Please configure IMAP settings"
            }
            return
        }

        DispatchQueue.main.async {
            self.isLoading = true
            self.errorMessage = nil
        }

        let startTime = Date()
        print("[EmailManager] [\(folderConfig.name)] Starting fetch")
        print("[EmailManager] [\(folderConfig.name)] Folder path: \(folderConfig.folderPath)")
        print("[EmailManager] [\(folderConfig.name)] Max emails: \(folderConfig.maxEmails), Days: \(folderConfig.daysToFetch)")
        print("[EmailManager] [\(folderConfig.name)] Filter groups: \(folderConfig.filterGroups.count)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let imapConfig = IMAPConfig(
                host: self.account.host,
                port: self.account.port,
                username: self.account.username,
                password: self.account.password,
                useSSL: self.account.useSSL
            )

            do {
                // Use connection pool for better performance (per-folder connections)
                let folderPath = self.folderConfig.folderPath
                let connection = try self.connectionPool.getConnection(for: imapConfig, folder: folderPath)

                let highestCachedUID = forceFullRefresh ? 0 : self.cache.getHighestUID(for: self.cacheKey)

                print("[EmailManager] [\(self.folderConfig.name)] Connected, fetching (highestCachedUID: \(highestCachedUID))")

                // Get fetch settings from folder config
                let maxEmails = self.folderConfig.maxEmails  // 0 = unlimited
                let daysToFetch = self.folderConfig.daysToFetch  // 0 = all time

                // Use delta fetch if we have cached emails
                let fetchedEmails: [Email]
                if highestCachedUID > 0 && !forceFullRefresh {
                    // Fetch only new emails since last known UID
                    fetchedEmails = try connection.fetchEmailsSince(
                        folder: folderPath,
                        sinceUID: highestCachedUID,
                        limit: maxEmails > 0 ? maxEmails : 500
                    )
                    print("[EmailManager] [\(self.folderConfig.name)] Delta fetch: \(fetchedEmails.count) new emails")
                } else {
                    // Build server-side search query from filter groups
                    let searchQuery = self.buildServerSearchQuery()

                    // Full fetch with configured limits and optional server-side search
                    fetchedEmails = try connection.fetchEmails(
                        folder: folderPath,
                        limit: maxEmails,
                        daysBack: daysToFetch,
                        searchQuery: searchQuery
                    )
                    print("[EmailManager] [\(self.folderConfig.name)] Full fetch: \(fetchedEmails.count) emails (max=\(maxEmails), days=\(daysToFetch), search=\(searchQuery ?? "none"))")
                }

                // Return connection to pool (keep alive)
                self.connectionPool.returnConnection(connection, for: imapConfig, folder: folderPath)
                
                // Merge with cache
                let allEmails: [Email]
                if highestCachedUID > 0 && !forceFullRefresh {
                    allEmails = self.cache.mergeNewEmails(fetchedEmails, for: self.cacheKey, maxEmails: maxEmails)
                } else {
                    allEmails = fetchedEmails.sorted { $0.date > $1.date }
                }
                
                // Update cache
                self.cache.setCachedEmails(allEmails, for: self.cacheKey)

                // Apply filters
                let filteredEmails = self.applyFilters(to: allEmails)
                
                let fetchDuration = Date().timeIntervalSince(startTime)
                
                DispatchQueue.main.async {
                    self.emails = filteredEmails
                    self.unreadCount = filteredEmails.filter { !$0.isRead }.count
                    self.isConnected = true
                    self.isLoading = false
                    self.secondsUntilRefresh = self.refreshInterval
                    self.lastFetchDuration = fetchDuration
                    print("[EmailManager] [\(self.folderConfig.name)] Done in \(String(format: "%.2f", fetchDuration))s, showing \(filteredEmails.count) emails")
                }
            } catch {
                print("[EmailManager] Error: \(error)")
                // Invalidate connection on error
                self.connectionPool.invalidateConnection(for: imapConfig, folder: self.folderConfig.folderPath)
                
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isConnected = false
                    self.isLoading = false
                }
            }
        }
    }
    
    private func applyFilters(to emails: [Email]) -> [Email] {
        let filtered = emails.filter { self.folderConfig.matchesFilters(email: $0, accountEmail: self.account.emailAddress) }
        if filtered.count < emails.count {
            print("[EmailManager] [\(folderConfig.name)] Filtered to \(filtered.count) emails (from \(emails.count))")
        }
        return filtered
    }
    
    /// Build IMAP SEARCH query from filter groups that have server search enabled
    private func buildServerSearchQuery() -> String? {
        let serverSearchGroups = folderConfig.filterGroups.filter { $0.enabled && $0.useServerSearch }
        guard !serverSearchGroups.isEmpty else { return nil }
        
        var queries: [String] = []
        for group in serverSearchGroups {
            if let query = group.buildIMAPSearchQuery() {
                queries.append(query)
            }
        }
        
        guard !queries.isEmpty else { return nil }
        
        if queries.count == 1 {
            return queries[0]
        }
        
        // Combine multiple group queries
        if folderConfig.groupLogic == .or {
            // OR them together
            var result = queries[0]
            for i in 1..<queries.count {
                result = "OR (\(result)) (\(queries[i]))"
            }
            return result
        } else {
            // AND them together (implicit in IMAP)
            return queries.joined(separator: " ")
        }
    }

    func markAsRead(_ email: Email) {
        guard !account.host.isEmpty else { return }

        // Optimistic UI update
        if let index = self.emails.firstIndex(where: { $0.id == email.id }) {
            self.emails[index].isRead = true
            self.unreadCount = self.emails.filter { !$0.isRead }.count
            
            // Update cache
            cache.updateEmail(self.emails[index], for: cacheKey)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let folderPath = self.folderConfig.folderPath
            do {
                let imapConfig = IMAPConfig(
                    host: self.account.host,
                    port: self.account.port,
                    username: self.account.username,
                    password: self.account.password,
                    useSSL: self.account.useSSL
                )
                let connection = try self.connectionPool.getConnection(for: imapConfig, folder: folderPath)
                try connection.markAsRead(folder: folderPath, uid: email.uid)
                self.connectionPool.returnConnection(connection, for: imapConfig, folder: folderPath)
            } catch {
                DispatchQueue.main.async {
                    if let index = self.emails.firstIndex(where: { $0.id == email.id }) {
                        self.emails[index].isRead = false
                        self.unreadCount = self.emails.filter { !$0.isRead }.count
                    }
                    self.errorMessage = "Failed to mark as read: \(error.localizedDescription)"
                }
            }
        }
    }

    func markAsUnread(_ email: Email) {
        guard !account.host.isEmpty else { return }

        if let index = self.emails.firstIndex(where: { $0.id == email.id }) {
            self.emails[index].isRead = false
            self.unreadCount = self.emails.filter { !$0.isRead }.count

            cache.updateEmail(self.emails[index], for: cacheKey)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let folderPath = self.folderConfig.folderPath
            do {
                let imapConfig = IMAPConfig(
                    host: self.account.host,
                    port: self.account.port,
                    username: self.account.username,
                    password: self.account.password,
                    useSSL: self.account.useSSL
                )
                let connection = try self.connectionPool.getConnection(for: imapConfig, folder: folderPath)
                try connection.markAsUnread(folder: folderPath, uid: email.uid)
                self.connectionPool.returnConnection(connection, for: imapConfig, folder: folderPath)
            } catch {
                DispatchQueue.main.async {
                    if let index = self.emails.firstIndex(where: { $0.id == email.id }) {
                        self.emails[index].isRead = true
                        self.unreadCount = self.emails.filter { !$0.isRead }.count
                    }
                    self.errorMessage = "Failed to mark as unread: \(error.localizedDescription)"
                }
            }
        }
    }

    func deleteEmail(_ email: Email) {
        guard !account.host.isEmpty else { return }

        emails.removeAll { $0.id == email.id }
        unreadCount = emails.filter { !$0.isRead }.count

        cache.removeEmail(uid: email.uid, from: cacheKey)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let folderPath = self.folderConfig.folderPath
            do {
                let imapConfig = IMAPConfig(
                    host: self.account.host,
                    port: self.account.port,
                    username: self.account.username,
                    password: self.account.password,
                    useSSL: self.account.useSSL
                )
                let connection = try self.connectionPool.getConnection(for: imapConfig, folder: folderPath)
                try connection.deleteEmail(folder: folderPath, uid: email.uid)
                self.connectionPool.returnConnection(connection, for: imapConfig, folder: folderPath)
            } catch {
                DispatchQueue.main.async {
                    self.emails.append(email)
                    self.emails.sort { $0.date > $1.date }
                    self.unreadCount = self.emails.filter { !$0.isRead }.count
                    self.errorMessage = "Failed to delete: \(error.localizedDescription)"
                }
            }
        }
    }

    func refresh() {
        fetchEmails(forceFullRefresh: true)
    }

    func fetchFullBody(for email: Email, completion: @escaping (String) -> Void) {
        guard !account.host.isEmpty else {
            completion("")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let folderPath = self.folderConfig.folderPath
            do {
                let imapConfig = IMAPConfig(
                    host: self.account.host,
                    port: self.account.port,
                    username: self.account.username,
                    password: self.account.password,
                    useSSL: self.account.useSSL
                )
                let connection = try self.connectionPool.getConnection(for: imapConfig, folder: folderPath)
                let fullMessage = try connection.fetchFullMessage(folder: folderPath, uid: email.uid)
                self.connectionPool.returnConnection(connection, for: imapConfig, folder: folderPath)

                var body = fullMessage
                if let headerEnd = fullMessage.range(of: "\r\n\r\n") {
                    body = String(fullMessage[headerEnd.upperBound...])
                }

                DispatchQueue.main.async {
                    completion(body)
                }
            } catch {
                print("[EmailManager] Failed to fetch full body: \(error)")
                DispatchQueue.main.async {
                    completion("")
                }
            }
        }
    }
}
