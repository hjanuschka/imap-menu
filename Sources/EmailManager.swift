import Foundation
import Combine

struct Email: Identifiable, Hashable, Codable {
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
    private let maxEmailsPerFolder = 500  // Hard limit to prevent memory explosion (reduced from 1000)
    private let maxTotalEmails = 2000  // Global limit across all folders
    
    private let cacheDirectory: URL
    
    private init() {
        // Set up cache directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDirectory = appSupport.appendingPathComponent("IMAPMenu/EmailCache", isDirectory: true)
        
        // Create directory if needed
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // Load persisted cache
        loadFromDisk()
    }
    
    private func cacheFileURL(for folderPath: String) -> URL {
        let safeName = folderPath.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return cacheDirectory.appendingPathComponent("\(safeName).json")
    }
    
    private func loadFromDisk() {
        cacheQueue.async(flags: .barrier) {
            guard let files = try? FileManager.default.contentsOfDirectory(at: self.cacheDirectory, includingPropertiesForKeys: nil) else {
                return
            }
            
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let cached = try? JSONDecoder().decode(CachedFolder.self, from: data) else {
                    continue
                }
                
                // Only load if not too old (max 1 hour)
                if Date().timeIntervalSince(cached.lastFetchTime) < 3600 {
                    self.cache[cached.folderPath] = cached.emails
                    self.lastFetchTime[cached.folderPath] = cached.lastFetchTime
                    self.highestUID[cached.folderPath] = cached.highestUID
                    debugLog("[EmailCache] Loaded \(cached.emails.count) emails from disk for \(cached.folderPath)")
                }
            }
        }
    }
    
    private func saveToDisk(folderPath: String) {
        guard let emails = cache[folderPath],
              let lastFetch = lastFetchTime[folderPath] else { return }
        
        let cached = CachedFolder(
            folderPath: folderPath,
            emails: emails,
            lastFetchTime: lastFetch,
            highestUID: highestUID[folderPath] ?? 0
        )
        
        DispatchQueue.global(qos: .utility).async {
            do {
                let data = try JSONEncoder().encode(cached)
                try data.write(to: self.cacheFileURL(for: folderPath))
                debugLog("[EmailCache] Saved \(emails.count) emails to disk for \(folderPath)")
            } catch {
                debugLog("[EmailCache] Failed to save: \(error)")
            }
        }
    }
    
    private struct CachedFolder: Codable {
        let folderPath: String
        let emails: [Email]
        let lastFetchTime: Date
        let highestUID: UInt32
    }

    func getCachedEmails(for folderPath: String) -> [Email]? {
        cacheQueue.sync {
            return cache[folderPath]
        }
    }

    func setCachedEmails(_ emails: [Email], for folderPath: String) {
        cacheQueue.async(flags: .barrier) {
            // Enforce per-folder limit
            let limitedEmails = emails.count > self.maxEmailsPerFolder
                ? Array(emails.prefix(self.maxEmailsPerFolder))
                : emails
            self.cache[folderPath] = limitedEmails
            self.lastFetchTime[folderPath] = Date()
            if let maxUID = limitedEmails.map({ $0.uid }).max() {
                self.highestUID[folderPath] = maxUID
            }
            
            // Enforce global limit - evict oldest folders if needed
            let totalCount = self.cache.values.reduce(0) { $0 + $1.count }
            if totalCount > self.maxTotalEmails {
                debugLog("[EmailCache] WARNING: Total cached emails (\(totalCount)) exceeds limit (\(self.maxTotalEmails)), evicting oldest")
                // Sort by last fetch time, evict oldest first
                let sortedPaths = self.lastFetchTime.sorted { $0.value < $1.value }.map { $0.key }
                var currentTotal = totalCount
                for path in sortedPaths where path != folderPath && currentTotal > self.maxTotalEmails {
                    if let count = self.cache[path]?.count {
                        self.cache.removeValue(forKey: path)
                        self.lastFetchTime.removeValue(forKey: path)
                        self.highestUID.removeValue(forKey: path)
                        currentTotal -= count
                        debugLog("[EmailCache] Evicted \(path) (\(count) emails)")
                    }
                }
            }
            
            // Save to disk for persistence across app restarts
            self.saveToDisk(folderPath: folderPath)
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
            
            // ALWAYS enforce hard limit to prevent memory explosion
            let effectiveLimit = maxEmails > 0 ? min(maxEmails, maxEmailsPerFolder) : maxEmailsPerFolder
            if existing.count > effectiveLimit {
                existing = Array(existing.prefix(effectiveLimit))
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
    
    func clearAll() {
        cacheQueue.async(flags: .barrier) {
            let count = self.cache.values.reduce(0) { $0 + $1.count }
            self.cache.removeAll()
            self.lastFetchTime.removeAll()
            self.highestUID.removeAll()
            debugLog("[EmailCache] Cleared all cache (\(count) emails)")
        }
    }
    
    func totalCachedEmails() -> Int {
        cacheQueue.sync {
            return cache.values.reduce(0) { $0 + $1.count }
        }
    }
    
    func isCacheValid(for folderPath: String, maxAge: TimeInterval = 300) -> Bool {
        cacheQueue.sync {
            guard let lastFetch = lastFetchTime[folderPath] else { return false }
            return Date().timeIntervalSince(lastFetch) < maxAge
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
    @Published var fetchProgress: String = ""  // Shows "Loading 150/500..."
    @Published var lastSyncTime: Date?  // When we last successfully synced

    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    // Removed: private var notificationObserver - notifications now handled by AppDelegate only
    private let baseRefreshInterval: Int = 60
    private var currentRefreshInterval: Int = 60
    private var consecutiveNoNewEmails: Int = 0
    private var lastEmailCount: Int = 0

    private let cache = EmailCache.shared

    // Each folder gets its own dedicated connection and queue for true parallel fetching
    private var dedicatedConnection: IMAPConnection?
    private let fetchQueue: DispatchQueue
    private let connectionLock = NSLock()

    let account: IMAPAccount
    let folderConfig: FolderConfig

    init(account: IMAPAccount, folderConfig: FolderConfig) {
        self.account = account
        self.folderConfig = folderConfig

        // Create a unique queue for this folder
        let queueLabel = "com.imapmenu.fetch.\(account.id).\(folderConfig.id)"
        self.fetchQueue = DispatchQueue(label: queueLabel, qos: .userInitiated)

        // NOTE: Don't listen to RefreshEmails here - AppDelegate recreates all EmailManagers
        // when config changes, so listening here would cause duplicate fetches.
        // The startFetching() call in FolderMenuItem.init handles the initial fetch.
    }

    deinit {
        debugLog("[EmailManager] [\(folderConfig.name)] DEINIT - stopping fetching")
        stopFetching()
    }

    // IDLE mode support
    private var idleConnection: IMAPConnection?
    private var isIdleMode = false
    private var idleQueue: DispatchQueue?
    private var shouldStopIdle = false
    
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
        
        // Try to use IDLE if available, otherwise fall back to polling
        startIdleOrPolling()
    }
    
    /// Start IDLE mode if supported, otherwise use traditional polling
    private func startIdleOrPolling() {
        // First do an initial fetch to get connection and check capabilities
        let imapConfig = IMAPConfig(
            host: account.host,
            port: account.port,
            username: account.username,
            password: account.password,
            useSSL: account.useSSL
        )
        
        fetchQueue.async { [weak self] in
            guard let self = self else { return }
            
            do {
                let connection = try self.getOrCreateConnection(config: imapConfig)
                
                if connection.supportsIdle {
                    debugLog("[EmailManager] [\(self.folderConfig.name)] Server supports IDLE - using push notifications")
                    DispatchQueue.main.async {
                        self.startIdleMode()
                    }
                } else {
                    debugLog("[EmailManager] [\(self.folderConfig.name)] Server doesn't support IDLE - using polling")
                    DispatchQueue.main.async {
                        self.startTimers()
                    }
                }
            } catch {
                debugLog("[EmailManager] [\(self.folderConfig.name)] Connection failed, falling back to polling: \(error)")
                DispatchQueue.main.async {
                    self.startTimers()
                }
            }
        }
    }
    
    /// Start IDLE mode for real-time push notifications
    private func startIdleMode() {
        guard !isIdleMode else { return }
        
        isIdleMode = true
        shouldStopIdle = false
        
        // Create dedicated queue for IDLE
        let queueLabel = "com.imapmenu.idle.\(account.id).\(folderConfig.id)"
        idleQueue = DispatchQueue(label: queueLabel, qos: .utility)
        
        idleQueue?.async { [weak self] in
            self?.runIdleLoop()
        }
        
        debugLog("[EmailManager] [\(folderConfig.name)] IDLE mode started")
    }
    
    /// Stop IDLE mode
    private func stopIdleMode() {
        guard isIdleMode else { return }
        
        shouldStopIdle = true
        isIdleMode = false
        
        // Stop IDLE on the connection
        connectionLock.lock()
        if let connection = idleConnection {
            try? connection.stopIdle()
            connection.disconnect()
        }
        idleConnection = nil
        connectionLock.unlock()
        
        debugLog("[EmailManager] [\(folderConfig.name)] IDLE mode stopped")
    }
    
    /// Main IDLE loop - runs on dedicated queue
    private func runIdleLoop() {
        let imapConfig = IMAPConfig(
            host: account.host,
            port: account.port,
            username: account.username,
            password: account.password,
            useSSL: account.useSSL
        )
        
        while !shouldStopIdle {
            do {
                // Create dedicated IDLE connection
                connectionLock.lock()
                if idleConnection == nil || !idleConnection!.isConnected {
                    let connection = IMAPConnection(config: imapConfig)
                    try connection.connect()
                    idleConnection = connection
                }
                let connection = idleConnection!
                connectionLock.unlock()
                
                // Select the folder
                _ = try connection.selectFolder(folderConfig.folderPath, forceReselect: true)
                
                // Start IDLE
                try connection.startIdle()
                
                // Update UI to show we're in real-time mode
                DispatchQueue.main.async {
                    self.secondsUntilRefresh = -1  // -1 indicates IDLE mode
                }
                
                // Wait for updates (29 minutes max - RFC recommends re-issuing IDLE before 30 min)
                // Check every second for notifications or stop signal
                var idleTime: TimeInterval = 0
                let maxIdleTime: TimeInterval = 29 * 60  // 29 minutes
                
                while !shouldStopIdle && idleTime < maxIdleTime {
                    if let notification = connection.checkIdleUpdate() {
                        // Got a notification - fetch new emails
                        handleIdleNotification(notification)
                    }
                    
                    Thread.sleep(forTimeInterval: 1)
                    idleTime += 1
                }
                
                // Stop IDLE and restart loop
                try connection.stopIdle()
                
            } catch {
                debugLog("[EmailManager] [\(folderConfig.name)] IDLE error: \(error)")
                
                connectionLock.lock()
                idleConnection?.disconnect()
                idleConnection = nil
                connectionLock.unlock()
                
                // Wait before reconnecting
                if !shouldStopIdle {
                    Thread.sleep(forTimeInterval: 5)
                }
            }
        }
    }
    
    /// Handle notification received during IDLE
    private func handleIdleNotification(_ notification: IMAPConnection.IdleNotification) {
        switch notification {
        case .exists(let count):
            debugLog("[EmailManager] [\(folderConfig.name)] IDLE: New message! Total: \(count)")
            // Fetch new emails
            DispatchQueue.main.async {
                self.fetchEmails(forceFullRefresh: false)
            }
            
        case .expunge(let seq):
            debugLog("[EmailManager] [\(folderConfig.name)] IDLE: Message \(seq) deleted")
            // Refresh to update list
            DispatchQueue.main.async {
                self.fetchEmails(forceFullRefresh: false)
            }
            
        case .recent(let count):
            debugLog("[EmailManager] [\(folderConfig.name)] IDLE: \(count) recent messages")
            if count > 0 {
                DispatchQueue.main.async {
                    self.fetchEmails(forceFullRefresh: false)
                }
            }
            
        case .fetch(let seq):
            debugLog("[EmailManager] [\(folderConfig.name)] IDLE: Flags changed for message \(seq)")
            // Could refresh just that message's flags, but for simplicity do a delta fetch
            DispatchQueue.main.async {
                self.fetchEmails(forceFullRefresh: false)
            }
        }
    }
    
    private var cacheKey: String {
        return "\(account.id):\(folderConfig.folderPath)"
    }

    // MARK: - Dedicated Connection Management

    private func getOrCreateConnection(config: IMAPConfig) throws -> IMAPConnection {
        // Check if we already have a valid connection (quick check with lock)
        connectionLock.lock()
        if let existing = dedicatedConnection, existing.isConnected {
            connectionLock.unlock()
            debugLog("[EmailManager] [\(folderConfig.name)] Reusing dedicated connection")
            return existing
        }
        connectionLock.unlock()

        // Create new connection OUTSIDE the lock (connect() does network I/O)
        debugLog("[EmailManager] [\(folderConfig.name)] Creating new dedicated connection")
        let connection = IMAPConnection(config: config)
        try connection.connect()
        
        // Store it with the lock
        connectionLock.lock()
        dedicatedConnection = connection
        connectionLock.unlock()
        
        return connection
    }

    private func invalidateConnection() {
        connectionLock.lock()
        defer { connectionLock.unlock() }

        dedicatedConnection?.disconnect()
        dedicatedConnection = nil
    }

    private var keepAliveTimer: Timer?
    
    /// Computed property for adaptive refresh interval
    private var refreshInterval: Int {
        return currentRefreshInterval
    }
    
    private func startTimers() {
        stopTimers()
        
        currentRefreshInterval = baseRefreshInterval
        secondsUntilRefresh = currentRefreshInterval

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if self.secondsUntilRefresh > 0 {
                    self.secondsUntilRefresh -= 1
                }
            }
        }

        scheduleNextRefresh()
        
        // Keep-alive: send NOOP every 4 minutes to prevent connection timeout
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 240, repeats: true) { [weak self] _ in
            self?.sendKeepAlive()
        }
    }
    
    private func scheduleNextRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Double(currentRefreshInterval), repeats: false) { [weak self] _ in
            self?.fetchEmails(forceFullRefresh: false)
        }
    }
    
    /// Update refresh interval based on email activity
    private func updateAdaptiveRefreshInterval(newEmailCount: Int) {
        let currentCount = emails.count
        
        if currentCount == lastEmailCount {
            // No new emails
            consecutiveNoNewEmails += 1
            
            // Gradually increase interval: 60s -> 90s -> 120s -> 180s (max 3 min)
            if consecutiveNoNewEmails >= 3 {
                currentRefreshInterval = min(180, baseRefreshInterval + (consecutiveNoNewEmails - 2) * 30)
                debugLog("[EmailManager] [\(folderConfig.name)] No new emails, slowing to \(currentRefreshInterval)s")
            }
        } else {
            // New emails arrived - reset to base interval
            consecutiveNoNewEmails = 0
            if currentRefreshInterval != baseRefreshInterval {
                currentRefreshInterval = baseRefreshInterval
                debugLog("[EmailManager] [\(folderConfig.name)] New emails, resetting to \(baseRefreshInterval)s")
            }
        }
        
        lastEmailCount = currentCount
        
        DispatchQueue.main.async {
            self.secondsUntilRefresh = self.currentRefreshInterval
        }
        
        scheduleNextRefresh()
    }
    
    private func sendKeepAlive() {
        connectionLock.lock()
        guard let connection = dedicatedConnection, connection.isConnected else {
            connectionLock.unlock()
            return
        }
        connectionLock.unlock()
        
        fetchQueue.async { [weak self] in
            guard let self = self else { return }
            self.connectionLock.lock()
            guard let conn = self.dedicatedConnection else {
                self.connectionLock.unlock()
                return
            }
            self.connectionLock.unlock()
            
            do {
                try conn.noop()
                debugLog("[EmailManager] [\(self.folderConfig.name)] Keep-alive NOOP sent")
            } catch {
                debugLog("[EmailManager] [\(self.folderConfig.name)] Keep-alive failed, invalidating connection")
                self.invalidateConnection()
            }
        }
    }

    private func stopTimers() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    func stopFetching() {
        stopTimers()
        stopIdleMode()
        invalidateConnection()
    }

    private var isFetching = false  // Prevent concurrent fetches
    private let maxUnreadBeforeSkip = 99  // Stop fetching when we have this many unread

    func fetchEmails(forceFullRefresh: Bool = false) {
        guard !account.host.isEmpty else {
            DispatchQueue.main.async {
                self.errorMessage = "Please configure IMAP settings"
            }
            return
        }

        // Skip fetch if we already have 99+ unread - no point fetching more
        if unreadCount >= maxUnreadBeforeSkip && !forceFullRefresh {
            debugLog("[EmailManager] [\(folderConfig.name)] Skipping fetch - already have \(unreadCount) unread (max: \(maxUnreadBeforeSkip))")
            return
        }

        // Prevent concurrent fetches - if already fetching, skip this one
        guard !isFetching else {
            debugLog("[EmailManager] [\(folderConfig.name)] Skipping fetch - already in progress")
            return
        }
        isFetching = true

        DispatchQueue.main.async {
            self.isLoading = true
            self.errorMessage = nil
        }

        let startTime = Date()
        debugLog("[EmailManager] [\(folderConfig.name)] Starting fetch on dedicated queue")
        debugLog("[EmailManager] [\(folderConfig.name)] Folder path: \(folderConfig.folderPath)")
        debugLog("[EmailManager] [\(folderConfig.name)] Max emails: \(folderConfig.maxEmails), Days: \(folderConfig.daysToFetch)")
        debugLog("[EmailManager] [\(folderConfig.name)] Filter groups: \(folderConfig.filterGroups.count)")

        // Use dedicated queue for this folder - allows parallel fetching across folders
        fetchQueue.async { [weak self] in
            guard let self = self else { return }

            let imapConfig = IMAPConfig(
                host: self.account.host,
                port: self.account.port,
                username: self.account.username,
                password: self.account.password,
                useSSL: self.account.useSSL
            )

            do {
                let folderPath = self.folderConfig.folderPath
                let highestCachedUID = forceFullRefresh ? 0 : self.cache.getHighestUID(for: self.cacheKey)
                
                // Get fetch settings from folder config
                let maxEmails = self.folderConfig.maxEmails  // 0 = unlimited
                let daysToFetch = self.folderConfig.daysToFetch  // 0 = all time

                // Use delta fetch if we have cached emails
                let fetchedEmails: [Email]
                if highestCachedUID > 0 && !forceFullRefresh {
                    // Delta fetch uses dedicated connection (reusable)
                    let connection = try self.getOrCreateConnection(config: imapConfig)
                    debugLog("[EmailManager] [\(self.folderConfig.name)] Connected, delta fetch (highestCachedUID: \(highestCachedUID))")
                    
                    fetchedEmails = try connection.fetchEmailsSince(
                        folder: folderPath,
                        sinceUID: highestCachedUID,
                        limit: maxEmails > 0 ? maxEmails : 500
                    )
                    debugLog("[EmailManager] [\(self.folderConfig.name)] Delta fetch: \(fetchedEmails.count) new emails")
                } else {
                    // Full fetch uses parallel connections (creates its own)
                    debugLog("[EmailManager] [\(self.folderConfig.name)] Starting full parallel fetch (highestCachedUID: \(highestCachedUID))")
                    // Build server-side search query from filter groups
                    let searchQuery = self.buildServerSearchQuery()

                    // Use PARALLEL fetch with multiple connections for speed
                    // Hard cap to prevent memory explosion
                    let hardCap = 500
                    var accumulatedEmails: [Email] = []
                    accumulatedEmails.reserveCapacity(min(maxEmails > 0 ? maxEmails : hardCap, hardCap))
                    let emailsLock = NSLock()
                    var isFirstBatch = true
                    let targetCount = min(maxEmails > 0 ? maxEmails : hardCap, hardCap)

                    let semaphore = DispatchSemaphore(value: 0)
                    var fetchError: Error?

                    // Track unread count for early cancellation
                    var currentUnreadCount = 0
                    let unreadLock = NSLock()
                    
                    IMAPConnection.fetchEmailsParallel(
                        config: imapConfig,
                        folder: folderPath,
                        limit: maxEmails,
                        daysBack: daysToFetch,
                        searchQuery: searchQuery,
                        shouldCancel: {
                            // Cancel if we've hit 99+ unread
                            unreadLock.lock()
                            let count = currentUnreadCount
                            unreadLock.unlock()
                            return count >= 99
                        },
                        onBatch: { batchEmails in
                            emailsLock.lock()
                            accumulatedEmails.append(contentsOf: batchEmails)
                            // Sort by date descending (newest first) - consistent sorting
                            accumulatedEmails.sort { $0.date > $1.date }
                            // Trim to hard cap to prevent memory explosion during fetch
                            if accumulatedEmails.count > hardCap {
                                accumulatedEmails = Array(accumulatedEmails.prefix(hardCap))
                            }
                            let currentCount = accumulatedEmails.count
                            let sortedEmails = accumulatedEmails
                            emailsLock.unlock()

                            // Apply filters
                            let filteredEmails = self.applyFilters(to: sortedEmails)
                            let unreadInBatch = filteredEmails.filter { !$0.isRead }.count
                            
                            // Update shared unread count for cancellation check
                            unreadLock.lock()
                            currentUnreadCount = unreadInBatch
                            unreadLock.unlock()

                            // Update UI immediately with each batch
                            DispatchQueue.main.async {
                                self.emails = filteredEmails
                                self.unreadCount = unreadInBatch
                                self.isConnected = true
                                
                                // Show progress, or indicate we're stopping early
                                if unreadInBatch >= self.maxUnreadBeforeSkip {
                                    self.fetchProgress = "99+ unread, stopping..."
                                } else {
                                    self.fetchProgress = "Loading \(currentCount)/\(targetCount)..."
                                }

                                // Only hide loading spinner after first batch
                                if isFirstBatch {
                                    self.isLoading = false
                                    isFirstBatch = false
                                }
                            }
                        },
                        onComplete: { error in
                            fetchError = error
                            semaphore.signal()
                        }
                    )

                    // Wait for parallel fetch to complete (with timeout to prevent deadlock)
                    let waitResult = semaphore.wait(timeout: .now() + 180)  // 3 minute max
                    if waitResult == .timedOut {
                        debugLog("[EmailManager] [\(self.folderConfig.name)] WARNING: Fetch timed out after 180s")
                    }

                    if let error = fetchError {
                        throw error
                    }

                    emailsLock.lock()
                    fetchedEmails = accumulatedEmails
                    emailsLock.unlock()
                    debugLog("[EmailManager] [\(self.folderConfig.name)] Parallel fetch complete: \(fetchedEmails.count) emails")
                }

                // Final sort by date
                let allEmails: [Email]
                if highestCachedUID > 0 && !forceFullRefresh {
                    allEmails = self.cache.mergeNewEmails(fetchedEmails, for: self.cacheKey, maxEmails: maxEmails)
                } else {
                    allEmails = fetchedEmails.sorted { $0.date > $1.date }
                }

                // Update cache
                self.cache.setCachedEmails(allEmails, for: self.cacheKey)

                // Final UI update with sorted emails
                let filteredEmails = self.applyFilters(to: allEmails)

                let fetchDuration = Date().timeIntervalSince(startTime)

                DispatchQueue.main.async {
                    self.emails = filteredEmails
                    self.unreadCount = filteredEmails.filter { !$0.isRead }.count
                    self.isConnected = true
                    self.isLoading = false
                    self.isFetching = false
                    self.fetchProgress = ""  // Clear progress
                    self.secondsUntilRefresh = self.refreshInterval
                    self.lastFetchDuration = fetchDuration
                    self.lastSyncTime = Date()
                    
                    // Notify about new unread emails
                    NotificationManager.shared.notifyNewEmails(
                        filteredEmails,
                        folderName: self.folderConfig.name,
                        folderKey: self.cacheKey
                    )
                    
                    // Update adaptive refresh interval based on activity
                    self.updateAdaptiveRefreshInterval(newEmailCount: filteredEmails.count)
                    
                    debugLog("[EmailManager] [\(self.folderConfig.name)] Done in \(String(format: "%.2f", fetchDuration))s, showing \(filteredEmails.count) emails")
                }
            } catch {
                debugLog("[EmailManager] [\(self.folderConfig.name)] Error: \(error)")
                // Invalidate dedicated connection on error
                self.invalidateConnection()

                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isConnected = false
                    self.fetchProgress = ""
                    self.isLoading = false
                    self.isFetching = false
                }
            }
        }
    }
    
    private func applyFilters(to emails: [Email]) -> [Email] {
        let filtered = emails.filter { self.folderConfig.matchesFilters(email: $0, accountEmail: self.account.emailAddress) }
        if filtered.count < emails.count {
            debugLog("[EmailManager] [\(folderConfig.name)] Filtered to \(filtered.count) emails (from \(emails.count))")
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

        fetchQueue.async { [weak self] in
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
                let connection = try self.getOrCreateConnection(config: imapConfig)
                try connection.markAsRead(folder: folderPath, uid: email.uid)
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

        fetchQueue.async { [weak self] in
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
                let connection = try self.getOrCreateConnection(config: imapConfig)
                try connection.markAsUnread(folder: folderPath, uid: email.uid)
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

        fetchQueue.async { [weak self] in
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
                let connection = try self.getOrCreateConnection(config: imapConfig)
                try connection.deleteEmail(folder: folderPath, uid: email.uid)
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

        fetchQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion("") }
                return
            }

            let folderPath = self.folderConfig.folderPath
            do {
                let imapConfig = IMAPConfig(
                    host: self.account.host,
                    port: self.account.port,
                    username: self.account.username,
                    password: self.account.password,
                    useSSL: self.account.useSSL
                )
                let connection = try self.getOrCreateConnection(config: imapConfig)
                let fullMessage = try connection.fetchFullMessage(folder: folderPath, uid: email.uid)

                var body = fullMessage
                if let headerEnd = fullMessage.range(of: "\r\n\r\n") {
                    body = String(fullMessage[headerEnd.upperBound...])
                }

                DispatchQueue.main.async {
                    completion(body)
                }
            } catch {
                debugLog("[EmailManager] Failed to fetch full body: \(error)")
                DispatchQueue.main.async {
                    completion("")
                }
            }
        }
    }
}
