import Foundation
import SwiftMail

/// A wrapper around SwiftMail's IMAPServer that provides a simpler interface for IMAPMenu
/// This replaces the custom IMAPConnection implementation with SwiftMail's robust IMAP handling
actor SwiftMailIMAPClient {
    private let config: IMAPConfig
    private var server: IMAPServer?
    private var currentFolder: String?
    
    // Cached mailbox status for the current folder
    private var currentMailboxStatus: Mailbox.Status?
    
    init(config: IMAPConfig) {
        self.config = config
    }
    
    // MARK: - Connection Management
    
    func connect() async throws {
        let server = IMAPServer(host: config.host, port: config.port)
        try await server.connect()
        
        // Handle different auth methods
        switch config.authMethod {
        case .password(let password):
            try await server.login(username: config.username, password: password)
        case .oauth2(let accessToken):
            try await server.authenticateXOAUTH2(email: config.username, accessToken: accessToken)
        }
        
        self.server = server
        print("[SwiftMail] Connected to \(config.host):\(config.port)")
    }
    
    func disconnect() async {
        guard let server = server else { return }
        do {
            try await server.disconnect()
            print("[SwiftMail] Disconnected")
        } catch {
            print("[SwiftMail] Disconnect error: \(error)")
        }
        self.server = nil
        self.currentFolder = nil
        self.currentMailboxStatus = nil
    }
    
    var isConnected: Bool {
        server != nil
    }
    
    // MARK: - Folder Operations
    
    func selectFolder(_ folder: String) async throws -> (exists: Int, uidNext: UInt32) {
        guard let server = server else {
            throw IMAPClientError.notConnected
        }
        
        // Encode folder name in modified UTF-7 for IMAP (handles emojis and special chars)
        let encodedFolder = encodeModifiedUTF7(folder)
        
        let status = try await server.selectMailbox(encodedFolder)
        currentFolder = folder
        currentMailboxStatus = status
        
        let uidNext = status.uidNext.value
        print("[SwiftMail] Selected '\(folder)': exists=\(status.messageCount), uidNext=\(uidNext)")
        
        return (exists: status.messageCount, uidNext: UInt32(uidNext))
    }
    
    // MARK: - Modified UTF-7 Encoding for IMAP folder names
    
    /// Encode a string to IMAP's modified UTF-7 format
    /// This handles non-ASCII characters like emojis in folder names
    private func encodeModifiedUTF7(_ string: String) -> String {
        var result = ""
        var nonASCIIBuffer = ""
        
        for char in string {
            if char.asciiValue != nil && char != "&" {
                // Flush any buffered non-ASCII characters
                if !nonASCIIBuffer.isEmpty {
                    result += "&" + encodeUTF7Segment(nonASCIIBuffer) + "-"
                    nonASCIIBuffer = ""
                }
                result.append(char)
            } else if char == "&" {
                // Flush buffer and encode & as &-
                if !nonASCIIBuffer.isEmpty {
                    result += "&" + encodeUTF7Segment(nonASCIIBuffer) + "-"
                    nonASCIIBuffer = ""
                }
                result += "&-"
            } else {
                // Buffer non-ASCII character
                nonASCIIBuffer.append(char)
            }
        }
        
        // Flush remaining buffer
        if !nonASCIIBuffer.isEmpty {
            result += "&" + encodeUTF7Segment(nonASCIIBuffer) + "-"
        }
        
        return result
    }
    
    /// Encode a UTF-16 string segment to modified base64
    private func encodeUTF7Segment(_ segment: String) -> String {
        // Convert to UTF-16 big-endian
        var utf16Bytes: [UInt8] = []
        for scalar in segment.unicodeScalars {
            let value = scalar.value
            if value <= 0xFFFF {
                // Basic Multilingual Plane
                utf16Bytes.append(UInt8((value >> 8) & 0xFF))
                utf16Bytes.append(UInt8(value & 0xFF))
            } else {
                // Supplementary planes (surrogate pairs)
                let adjusted = value - 0x10000
                let high = 0xD800 + ((adjusted >> 10) & 0x3FF)
                let low = 0xDC00 + (adjusted & 0x3FF)
                utf16Bytes.append(UInt8((high >> 8) & 0xFF))
                utf16Bytes.append(UInt8(high & 0xFF))
                utf16Bytes.append(UInt8((low >> 8) & 0xFF))
                utf16Bytes.append(UInt8(low & 0xFF))
            }
        }
        
        // Base64 encode and convert to modified base64 (/ -> ,)
        let base64 = Data(utf16Bytes).base64EncodedString()
            .replacingOccurrences(of: "/", with: ",")
            .replacingOccurrences(of: "=", with: "")  // Remove padding
        
        return base64
    }
    
    func listFolders() async throws -> [String] {
        guard let server = server else {
            throw IMAPClientError.notConnected
        }
        
        let mailboxes = try await server.listMailboxes()
        return mailboxes.map { $0.name }
    }
    
    // MARK: - Search Operations
    
    /// Search for emails matching criteria
    /// For large mailboxes, uses UID range to avoid PayloadTooLargeError
    func search(since: Date? = nil, limit: Int = 200) async throws -> [UInt32] {
        guard let server = server else {
            throw IMAPClientError.notConnected
        }
        
        // For large mailboxes (>10k messages), use UID-based approach to avoid huge search responses
        let messageCount = currentMailboxStatus?.messageCount ?? 0
        let uidNext = currentMailboxStatus?.uidNext.value ?? 0
        
        if messageCount > 10000 && limit > 0 {
            print("[SwiftMail] Large mailbox (\(messageCount) messages) - using UID range approach")
            return try await searchByUIDRange(uidNext: UInt32(uidNext), limit: limit, since: since)
        }
        
        // Standard search for smaller mailboxes
        var criteria: [SearchCriteria] = []
        
        if let since = since {
            criteria.append(.since(since))
        }
        
        // If no criteria, search all
        if criteria.isEmpty {
            criteria.append(.all)
        }
        
        let uidSet: MessageIdentifierSet<SwiftMail.UID> = try await server.search(criteria: criteria)
        
        // Convert to array and sort descending (newest first)
        var uids = uidSet.toArray().map { UInt32($0.value) }
        uids.sort(by: >)
        
        // Apply limit
        if limit > 0 && uids.count > limit {
            uids = Array(uids.prefix(limit))
        }
        
        print("[SwiftMail] Search found \(uidSet.count) UIDs, returning \(uids.count) (limit: \(limit))")
        return uids
    }
    
    /// For large mailboxes, fetch recent UIDs by range and filter by date client-side
    private func searchByUIDRange(uidNext: UInt32, limit: Int, since: Date?) async throws -> [UInt32] {
        guard let server = server else {
            throw IMAPClientError.notConnected
        }
        
        // Estimate: fetch 3x the limit to account for date filtering
        // Start from recent UIDs and work backwards
        let fetchCount = min(limit * 3, 1000)
        let startUID = uidNext > UInt32(fetchCount) ? uidNext - UInt32(fetchCount) : 1
        
        // Create UID range for recent messages
        let uidRange = SwiftMail.UID(startUID)...SwiftMail.UID(uidNext)
        let uidSet = MessageIdentifierSet<SwiftMail.UID>(uidRange)
        
        print("[SwiftMail] Fetching UID range \(startUID)...\(uidNext) (\(fetchCount) UIDs)")
        
        var matchingUIDs: [UInt32] = []
        
        // Fetch headers and filter by date
        for try await messageInfo in server.fetchMessageInfos(using: uidSet) {
            guard let uid = messageInfo.uid else { continue }
            
            // Filter by date if specified
            if let since = since, let date = messageInfo.date {
                if date < since {
                    continue  // Skip emails older than since date
                }
            }
            
            matchingUIDs.append(UInt32(uid.value))
            
            // Stop if we have enough
            if matchingUIDs.count >= limit {
                break
            }
        }
        
        // Sort descending (newest first)
        matchingUIDs.sort(by: >)
        
        print("[SwiftMail] UID range search found \(matchingUIDs.count) matching emails")
        return Array(matchingUIDs.prefix(limit))
    }
    
    // MARK: - Fetch Operations
    
    /// Fetch email headers for given UIDs
    func fetchHeaders(uids: [UInt32]) async throws -> [Email] {
        guard let server = server else {
            throw IMAPClientError.notConnected
        }
        
        guard !uids.isEmpty else { return [] }
        
        // Convert UIDs to SwiftMail's MessageIdentifierSet
        let swiftMailUIDs = uids.map { SwiftMail.UID($0) }
        let uidSet = MessageIdentifierSet<SwiftMail.UID>(swiftMailUIDs)
        
        var emails: [Email] = []
        
        // Fetch message infos (headers)
        for try await messageInfo in server.fetchMessageInfos(using: uidSet) {
            if let email = convertToEmail(messageInfo) {
                emails.append(email)
            }
        }
        
        print("[SwiftMail] Fetched \(emails.count) emails from \(uids.count) UIDs")
        return emails
    }
    
    /// Fetch full message body
    func fetchFullMessage(uid: UInt32) async throws -> String {
        guard let server = server else {
            throw IMAPClientError.notConnected
        }
        
        let swiftMailUID = SwiftMail.UID(uid)
        let uidSet = MessageIdentifierSet<SwiftMail.UID>([swiftMailUID])
        
        for try await message in server.fetchMessages(using: uidSet) {
            // Return HTML body if available, otherwise text body
            if let html = message.htmlBody {
                return html
            }
            if let text = message.textBody {
                // Wrap plain text in basic HTML
                return "<html><body><pre>\(text.htmlEscaped)</pre></body></html>"
            }
            return "<html><body><p>No body content</p></body></html>"
        }
        
        throw IMAPClientError.messageNotFound
    }
    
    // MARK: - Flag Operations
    
    func markAsRead(uid: UInt32) async throws {
        guard let server = server else {
            throw IMAPClientError.notConnected
        }
        
        let swiftMailUID = SwiftMail.UID(uid)
        let uidSet = MessageIdentifierSet<SwiftMail.UID>([swiftMailUID])
        try await server.store(flags: [.seen], on: uidSet, operation: .add)
        print("[SwiftMail] Marked UID \(uid) as read")
    }
    
    func markAsUnread(uid: UInt32) async throws {
        guard let server = server else {
            throw IMAPClientError.notConnected
        }
        
        let swiftMailUID = SwiftMail.UID(uid)
        let uidSet = MessageIdentifierSet<SwiftMail.UID>([swiftMailUID])
        try await server.store(flags: [.seen], on: uidSet, operation: .remove)
        print("[SwiftMail] Marked UID \(uid) as unread")
    }
    
    func deleteEmail(uid: UInt32) async throws {
        guard let server = server else {
            throw IMAPClientError.notConnected
        }
        
        let swiftMailUID = SwiftMail.UID(uid)
        let uidSet = MessageIdentifierSet<SwiftMail.UID>([swiftMailUID])
        try await server.store(flags: [.deleted], on: uidSet, operation: .add)
        try await server.expunge()
        print("[SwiftMail] Deleted UID \(uid)")
    }
    
    // MARK: - IDLE Support
    
    func startIdle() async throws -> AsyncStream<IMAPIdleEvent> {
        guard let server = server else {
            throw IMAPClientError.notConnected
        }
        
        let events = try await server.idle()
        
        // Transform SwiftMail events to our IMAPIdleEvent type
        return AsyncStream { continuation in
            Task {
                for await event in events {
                    switch event {
                    case .exists(let count):
                        continuation.yield(.exists(count))
                    case .expunge(let seqNum):
                        continuation.yield(.expunge(seqNum.value))
                    case .fetch(let seqNum, _):
                        // Flags changed on this sequence number - we don't parse the attributes here
                        continuation.yield(.flagsChanged(seqNum: seqNum.value, flags: []))
                    case .recent, .alert, .capability, .bye:
                        // Ignore these events for now
                        break
                    }
                }
                continuation.finish()
            }
        }
    }
    
    func stopIdle() async throws {
        guard let server = server else { return }
        try await server.done()
        print("[SwiftMail] IDLE stopped")
    }
    
    // MARK: - Conversion Helpers
    
    private func convertToEmail(_ info: MessageInfo) -> Email? {
        guard let uid = info.uid else {
            print("[SwiftMail] Skipping message without UID")
            return nil
        }
        
        let subject = info.subject ?? "(No Subject)"
        let from = info.from ?? "Unknown Sender"
        let to = info.to.joined(separator: ", ")
        let date = info.date ?? Date()
        
        // Parse from field into components
        let (fromName, fromEmail) = Email.parseFromField(from)
        
        // Check if read (has \Seen flag)
        let isRead = info.flags.contains(.seen)
        
        // Generate unique ID
        let messageId = info.messageId ?? "\(uid.value)@\(config.host)"
        
        return Email(
            id: messageId,
            uid: UInt32(uid.value),
            subject: subject,
            from: from,
            fromEmail: fromEmail,
            fromName: fromName,
            to: to,
            date: date,
            preview: "",  // Will be populated later if needed
            body: "",     // Will be fetched on demand
            contentType: "text/plain",
            boundary: "",
            isRead: isRead
        )
    }
    
    private func flagToString(_ flag: SwiftMail.Flag) -> String {
        switch flag {
        case .seen: return "\\Seen"
        case .answered: return "\\Answered"
        case .flagged: return "\\Flagged"
        case .deleted: return "\\Deleted"
        case .draft: return "\\Draft"
        case .custom(let name): return name
        }
    }
}

// MARK: - Errors

enum IMAPClientError: Error, LocalizedError {
    case notConnected
    case messageNotFound
    case folderNotSelected
    
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to IMAP server"
        case .messageNotFound: return "Message not found"
        case .folderNotSelected: return "No folder selected"
        }
    }
}

// MARK: - IDLE Events

enum IMAPIdleEvent {
    case exists(Int)
    case expunge(UInt32)
    case flagsChanged(seqNum: UInt32, flags: [String])
}

// MARK: - String Extension

private extension String {
    var htmlEscaped: String {
        self.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Static Parallel Fetch (replacement for IMAPConnection.fetchEmailsParallel)

extension SwiftMailIMAPClient {
    
    /// Fetch emails using SwiftMail - replacement for IMAPConnection.fetchEmailsParallel
    /// This uses SwiftMail's robust IMAP implementation instead of custom parsing
    static func fetchEmailsParallel(
        config: IMAPConfig,
        folder: String,
        limit: Int,
        daysBack: Int,
        searchQuery: String?,
        shouldCancel: (() -> Bool)?,
        onBatch: @escaping ([Email]) -> Void,
        onComplete: @escaping (Error?) -> Void
    ) {
        Task {
            do {
                let client = SwiftMailIMAPClient(config: config)
                try await client.connect()
                
                let _ = try await client.selectFolder(folder)
                
                // Calculate since date
                var sinceDate: Date? = nil
                if daysBack > 0 {
                    sinceDate = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date())
                }
                
                // Search for UIDs
                let uids = try await client.search(since: sinceDate, limit: limit)
                print("[SwiftMail] Found \(uids.count) UIDs to fetch")
                
                // Check cancellation
                if shouldCancel?() == true {
                    print("[SwiftMail] Cancelled before fetch")
                    await client.disconnect()
                    onComplete(nil)
                    return
                }
                
                // Fetch in batches of 50 for progress updates
                let batchSize = 50
                var allEmails: [Email] = []
                
                for batchStart in stride(from: 0, to: uids.count, by: batchSize) {
                    // Check cancellation
                    if shouldCancel?() == true {
                        print("[SwiftMail] Cancelled during fetch")
                        break
                    }
                    
                    let batchEnd = min(batchStart + batchSize, uids.count)
                    let batchUIDs = Array(uids[batchStart..<batchEnd])
                    
                    let batchEmails = try await client.fetchHeaders(uids: batchUIDs)
                    allEmails.append(contentsOf: batchEmails)
                    
                    print("[SwiftMail] Batch \(batchStart/batchSize + 1): fetched \(batchEmails.count) emails (total: \(allEmails.count))")
                    
                    // Call batch callback with just this batch (not accumulated)
                    onBatch(batchEmails)
                }
                
                await client.disconnect()
                print("[SwiftMail] Fetch complete: \(allEmails.count) emails")
                onComplete(nil)
                
            } catch {
                print("[SwiftMail] Error: \(error)")
                onComplete(error)
            }
        }
    }
}
