import Foundation
import Combine

struct Email: Identifiable, Hashable {
    let id: String
    let uid: UInt32
    let subject: String
    let from: String
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
}

// MIME Parser for extracting HTML/text content
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
        print("[MIMEParser] Starting getHTMLContent")
        print("[MIMEParser] Body length: \(body.count)")
        print("[MIMEParser] ContentType: \(contentType)")
        print("[MIMEParser] Boundary from header: \(boundary)")

        // First, try to find boundary in body if not provided
        var effectiveBoundary = boundary
        if effectiveBoundary.isEmpty {
            effectiveBoundary = findBoundaryInBody()
            print("[MIMEParser] Found boundary in body: \(effectiveBoundary)")
        }

        // Check if it's multipart
        if !effectiveBoundary.isEmpty && body.contains("--" + effectiveBoundary) {
            print("[MIMEParser] Parsing as multipart")
            let result = parseMultipart(boundary: effectiveBoundary)
            print("[MIMEParser] Multipart result length: \(result.count)")
            if !result.isEmpty {
                return result
            }
        }

        // Single part - decode based on content type
        if contentType.lowercased().contains("text/html") {
            print("[MIMEParser] Parsing as HTML")
            let decoded = decodeContent(body, headers: "Content-Type: \(contentType)")
            return decoded
        } else {
            // Plain text - convert to simple HTML
            print("[MIMEParser] Parsing as plain text")
            let decoded = decodeContent(body, headers: "Content-Type: \(contentType)")
            print("[MIMEParser] Decoded length: \(decoded.count)")
            let wrapped = wrapPlainText(decoded)
            print("[MIMEParser] Final HTML length: \(wrapped.count)")
            return wrapped
        }
    }

    private func findBoundaryInBody() -> String {
        // Look for boundary pattern in the body: --XXXXXXX followed by newline
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

        print("[MIMEParser] parseMultipart: found \(parts.count) parts")

        for (index, part) in parts.enumerated() {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            print("[MIMEParser] Part \(index): length=\(part.count), trimmed=\(trimmed.prefix(50))...")
            if trimmed.isEmpty || trimmed == "--" || trimmed.hasPrefix("--") { continue }

            // Split headers from body - look for double newline
            var headerEnd: Range<String.Index>?
            if let range = part.range(of: "\r\n\r\n") {
                headerEnd = range
            } else if let range = part.range(of: "\n\n") {
                headerEnd = range
            }

            guard let hEnd = headerEnd else { continue }

            let headers = String(part[..<hEnd.lowerBound])
            var content = String(part[hEnd.upperBound...])

            // Remove trailing boundary marker or closing dashes if present
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.hasSuffix("--") {
                content = String(content.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let headersLower = headers.lowercased()

            // Check for nested multipart
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

            // Check content type
            if headersLower.contains("text/html") {
                print("[MIMEParser] Found text/html part, RAW content length: \(content.count)")
                print("[MIMEParser] RAW HTML content: \(content)")
                print("[MIMEParser] HTML headers: \(headers)")
                let decoded = decodeContent(content, headers: headers)
                print("[MIMEParser] Decoded HTML length: \(decoded.count)")
                if !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    htmlContent = decoded
                }
            } else if headersLower.contains("text/plain") {
                print("[MIMEParser] Found text/plain part, content length: \(content.count)")
                let decoded = decodeContent(content, headers: headers)
                print("[MIMEParser] Decoded text length: \(decoded.count)")
                if !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    textContent = decoded
                }
            }
        }

        // Prefer HTML over plain text
        if let html = htmlContent, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ensureHTMLWrapper(html)
        }
        if let text = textContent, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return wrapPlainText(text)
        }

        // Last resort - try to extract any readable text
        return wrapPlainText(extractReadableText(from: body))
    }

    private func extractBoundary(from headers: String) -> String? {
        // Try multiple patterns
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

        // Check transfer encoding
        if headersLower.contains("quoted-printable") {
            result = decodeQuotedPrintable(result)
        } else if headersLower.contains("base64") {
            result = decodeBase64(result)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeQuotedPrintable(_ string: String) -> String {
        var result = string
        // Handle soft line breaks
        result = result.replacingOccurrences(of: "=\r\n", with: "")
        result = result.replacingOccurrences(of: "=\n", with: "")

        // Decode hex sequences
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
                // Non-ASCII character - encode as UTF-8
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
        // Strip MIME headers and boundaries, extract readable content
        var lines: [String] = []
        var inContent = false

        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip boundary lines
            if trimmed.hasPrefix("--") && trimmed.count > 20 {
                inContent = false
                continue
            }

            // Skip MIME headers
            if trimmed.lowercased().hasPrefix("content-") ||
               trimmed.lowercased().hasPrefix("mime-") {
                continue
            }

            // Empty line after headers signals content start
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

    // For preview text
    static func createPreview(from body: String, boundary: String) -> String {
        let parser = MIMEParser(body: body, contentType: "", boundary: boundary)

        var effectiveBoundary = boundary
        if effectiveBoundary.isEmpty {
            effectiveBoundary = parser.findBoundaryInBody()
        }

        var text = ""

        if !effectiveBoundary.isEmpty {
            // Extract text from multipart
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

        // Clean up
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

class EmailManager: ObservableObject {
    @Published var emails: [Email] = []
    @Published var isConnected = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var unreadCount: Int = 0
    @Published var secondsUntilRefresh: Int = 60

    private var imapConnection: IMAPConnection?
    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var notificationObserver: Any?
    private let refreshInterval: Int = 60

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
            self?.fetchEmails()
        }
    }

    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        stopFetching()
    }

    func startFetching() {
        fetchEmails()
        startTimers()
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
            self?.fetchEmails()
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
        imapConnection?.disconnect()
    }

    func fetchEmails() {
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
        print("[EmailManager] [\(folderConfig.name)] Starting fetch at \(startTime)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Create IMAPConfig from account
            let imapConfig = IMAPConfig(
                host: self.account.host,
                port: self.account.port,
                username: self.account.username,
                password: self.account.password,
                useSSL: self.account.useSSL
            )

            let connection = IMAPConnection(config: imapConfig)
            self.imapConnection = connection

            do {
                print("[EmailManager] [\(self.folderConfig.name)] Connecting... \(Date().timeIntervalSince(startTime))s")
                try connection.connect()
                print("[EmailManager] [\(self.folderConfig.name)] Connected! \(Date().timeIntervalSince(startTime))s")

                let fetchedEmails = try connection.fetchEmails(folder: self.folderConfig.folderPath, limit: 25)
                print("[EmailManager] [\(self.folderConfig.name)] Fetched \(fetchedEmails.count) emails in \(Date().timeIntervalSince(startTime))s")

                connection.disconnect()

                // Apply filters
                let filteredEmails = fetchedEmails.filter { self.folderConfig.matchesFilters(email: $0) }
                if filteredEmails.count < fetchedEmails.count {
                    print("[EmailManager] [\(self.folderConfig.name)] Filtered to \(filteredEmails.count) emails (from \(fetchedEmails.count))")
                }

                DispatchQueue.main.async {
                    self.emails = filteredEmails.sorted { $0.date > $1.date }
                    self.unreadCount = filteredEmails.filter { !$0.isRead }.count
                    self.isConnected = true
                    self.isLoading = false
                    self.secondsUntilRefresh = self.refreshInterval
                    print("[EmailManager] UI updated in \(Date().timeIntervalSince(startTime))s")
                }
            } catch {
                print("[EmailManager] Error after \(Date().timeIntervalSince(startTime))s: \(error)")
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isConnected = false
                    self.isLoading = false
                }
            }
        }
    }

    func markAsRead(_ email: Email) {
        guard !account.host.isEmpty else { return }

        // Optimistic UI update
        if let index = self.emails.firstIndex(where: { $0.id == email.id }) {
            self.emails[index].isRead = true
            self.unreadCount = self.emails.filter { !$0.isRead }.count
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                let imapConfig = IMAPConfig(
                    host: self.account.host,
                    port: self.account.port,
                    username: self.account.username,
                    password: self.account.password,
                    useSSL: self.account.useSSL
                )
                let connection = IMAPConnection(config: imapConfig)
                try connection.connect()
                try connection.markAsRead(folder: self.folderConfig.folderPath, uid: email.uid)
                connection.disconnect()
            } catch {
                // Revert on failure
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

        // Optimistic UI update
        if let index = self.emails.firstIndex(where: { $0.id == email.id }) {
            self.emails[index].isRead = false
            self.unreadCount = self.emails.filter { !$0.isRead }.count
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                let imapConfig = IMAPConfig(
                    host: self.account.host,
                    port: self.account.port,
                    username: self.account.username,
                    password: self.account.password,
                    useSSL: self.account.useSSL
                )
                let connection = IMAPConnection(config: imapConfig)
                try connection.connect()
                try connection.markAsUnread(folder: self.folderConfig.folderPath, uid: email.uid)
                connection.disconnect()
            } catch {
                // Revert on failure
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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                let imapConfig = IMAPConfig(
                    host: self.account.host,
                    port: self.account.port,
                    username: self.account.username,
                    password: self.account.password,
                    useSSL: self.account.useSSL
                )
                let connection = IMAPConnection(config: imapConfig)
                try connection.connect()
                try connection.deleteEmail(folder: self.folderConfig.folderPath, uid: email.uid)
                connection.disconnect()

                DispatchQueue.main.async {
                    self.emails.removeAll { $0.id == email.id }
                    self.unreadCount = self.emails.filter { !$0.isRead }.count
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to delete: \(error.localizedDescription)"
                }
            }
        }
    }

    func refresh() {
        fetchEmails()
    }

    func fetchFullBody(for email: Email, completion: @escaping (String) -> Void) {
        guard !account.host.isEmpty else {
            completion("")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let imapConfig = IMAPConfig(
                    host: self.account.host,
                    port: self.account.port,
                    username: self.account.username,
                    password: self.account.password,
                    useSSL: self.account.useSSL
                )
                let connection = IMAPConnection(config: imapConfig)
                try connection.connect()
                let fullMessage = try connection.fetchFullMessage(folder: self.folderConfig.folderPath, uid: email.uid)
                connection.disconnect()

                // Parse the full message to extract body
                // The full message includes headers + body
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
