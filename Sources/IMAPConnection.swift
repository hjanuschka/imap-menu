import Foundation
import Network

enum IMAPError: Error, LocalizedError {
    case connectionFailed(String)
    case authenticationFailed
    case folderNotFound(String)
    case fetchFailed(String)
    case invalidResponse(String)
    case timeout
    case noMessages
    case notConnected

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .authenticationFailed: return "Authentication failed"
        case .folderNotFound(let folder): return "Folder not found: \(folder)"
        case .fetchFailed(let msg): return "Fetch failed: \(msg)"
        case .invalidResponse(let msg): return "Invalid response: \(msg)"
        case .timeout: return "Connection timeout"
        case .noMessages: return "No messages in folder"
        case .notConnected: return "Not connected to server"
        }
    }
}

class IMAPConnection {
    private let config: IMAPConfig
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var tagCounter = 0
    private let timeout: TimeInterval = 30
    private var _isConnected = false
    private var currentFolder: String?
    private let connectionQueue = DispatchQueue(label: "com.imapmenu.connection")
    
    // Server capabilities
    private(set) var capabilities: Set<String> = []
    var supportsIdle: Bool { capabilities.contains("IDLE") }
    var supportsCondstore: Bool { capabilities.contains("CONDSTORE") }
    var supportsQResync: Bool { capabilities.contains("QRESYNC") }
    
    // IDLE state
    private var isIdling = false
    private var idleTag: String?
    
    var isConnected: Bool {
        connectionQueue.sync {
            guard _isConnected,
                  let input = inputStream,
                  let output = outputStream else {
                return false
            }
            return input.streamStatus == .open && output.streamStatus == .open
        }
    }

    init(config: IMAPConfig) {
        self.config = config
    }

    func connect() throws {
        let connectStart = Date()
        print("[IMAP] Starting connect to \(config.host):\(config.port)")

        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?

        CFStreamCreatePairWithSocketToHost(
            kCFAllocatorDefault,
            config.host as CFString,
            UInt32(config.port),
            &readStream,
            &writeStream
        )

        guard let inputStream = readStream?.takeRetainedValue() as InputStream?,
              let outputStream = writeStream?.takeRetainedValue() as OutputStream? else {
            throw IMAPError.connectionFailed("Failed to create streams")
        }

        self.inputStream = inputStream
        self.outputStream = outputStream

        if config.useSSL {
            inputStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
            outputStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)

            let sslSettings: [String: Any] = [
                kCFStreamSSLValidatesCertificateChain as String: true
            ]
            inputStream.setProperty(sslSettings, forKey: kCFStreamPropertySSLSettings as Stream.PropertyKey)
            outputStream.setProperty(sslSettings, forKey: kCFStreamPropertySSLSettings as Stream.PropertyKey)
        }

        inputStream.open()
        outputStream.open()

        let startTime = Date()
        while inputStream.streamStatus != .open || outputStream.streamStatus != .open {
            if Date().timeIntervalSince(startTime) > timeout {
                throw IMAPError.timeout
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        _ = try readResponse()
        print("[IMAP] Greeting received: \(Date().timeIntervalSince(connectStart))s")

        try login()
        
        connectionQueue.sync {
            _isConnected = true
        }
        
        print("[IMAP] Login complete: \(Date().timeIntervalSince(connectStart))s")
    }

    func disconnect() {
        connectionQueue.sync {
            _isConnected = false
            currentFolder = nil
        }
        _ = try? sendCommand("LOGOUT")
        inputStream?.close()
        outputStream?.close()
        inputStream = nil
        outputStream = nil
    }

    private func login() throws {
        // First get capabilities (use sendCommandDuringLogin to bypass isConnected check)
        let capResponse = try sendCommandDuringLogin("CAPABILITY")
        parseCapabilities(capResponse)
        
        // Authenticate based on method
        switch config.authMethod {
        case .password(let password):
            let response = try sendCommandDuringLogin("LOGIN \"\(config.username)\" \"\(password)\"")
            if !response.contains("OK") {
                throw IMAPError.authenticationFailed
            }
            
        case .oauth2(let accessToken):
            // Use XOAUTH2 for Gmail/OAuth2 authentication
            guard capabilities.contains("AUTH=XOAUTH2") || capabilities.contains("XOAUTH2") else {
                throw IMAPError.authenticationFailed
            }
            
            let xoauth2String = OAuth2Manager.generateXOAuth2String(email: config.username, accessToken: accessToken)
            let response = try sendCommandDuringLogin("AUTHENTICATE XOAUTH2 \(xoauth2String)")
            if !response.contains("OK") {
                // Parse error for better message
                if response.contains("AUTHENTICATIONFAILED") || response.contains("Invalid credentials") {
                    throw IMAPError.authenticationFailed
                }
                throw IMAPError.authenticationFailed
            }
        }
        
        // Capabilities may change after login, re-fetch
        let postLoginCap = try sendCommandDuringLogin("CAPABILITY")
        parseCapabilities(postLoginCap)
        
        // Enable QRESYNC if available (also enables CONDSTORE)
        if supportsQResync {
            _ = try? sendCommandDuringLogin("ENABLE QRESYNC")
            print("[IMAP] Enabled QRESYNC")
        } else if supportsCondstore {
            _ = try? sendCommandDuringLogin("ENABLE CONDSTORE")
            print("[IMAP] Enabled CONDSTORE")
        }
        
        print("[IMAP] Capabilities: IDLE=\(supportsIdle), CONDSTORE=\(supportsCondstore), QRESYNC=\(supportsQResync)")
    }
    
    /// Send command during login phase (bypasses isConnected check)
    private func sendCommandDuringLogin(_ command: String) throws -> String {
        let tag = nextTag()
        let fullCommand = "\(tag) \(command)\r\n"

        guard let data = fullCommand.data(using: .utf8),
              let outputStream = outputStream else {
            throw IMAPError.connectionFailed("Stream not available")
        }

        let bytesWritten = data.withUnsafeBytes { buffer in
            outputStream.write(buffer.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count)
        }

        if bytesWritten < 0 {
            throw IMAPError.connectionFailed("Failed to write to stream")
        }

        return try readResponse(untilTag: tag)
    }
    
    private func parseCapabilities(_ response: String) {
        // Parse CAPABILITY response: * CAPABILITY IMAP4rev1 IDLE CONDSTORE ...
        for line in response.components(separatedBy: "\r\n") {
            if line.contains("CAPABILITY") {
                let caps = line.uppercased()
                    .replacingOccurrences(of: "* CAPABILITY", with: "")
                    .components(separatedBy: " ")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                capabilities = Set(caps)
            }
        }
    }
    
    // MARK: - Optimized Folder Selection
    
    /// Result of SELECT command with CONDSTORE info
    struct SelectResult {
        var exists: Int = 0
        var recent: Int = 0
        var uidValidity: UInt32 = 0
        var uidNext: UInt32 = 0
        var highestModSeq: UInt64 = 0
    }
    
    @discardableResult
    func selectFolder(_ folder: String, forceReselect: Bool = false) throws -> SelectResult {
        // Skip if already selected (unless forced)
        if !forceReselect && currentFolder == folder {
            print("[IMAP] Folder '\(folder)' already selected, skipping SELECT")
            return SelectResult()
        }
        
        let encodedFolder = encodeModifiedUTF7(folder)
        
        // Use CONDSTORE modifier if available
        let selectCmd = supportsCondstore ? 
            "SELECT \"\(encodedFolder)\" (CONDSTORE)" : 
            "SELECT \"\(encodedFolder)\""
        
        let selectResponse = try sendCommand(selectCmd)
        
        var result = SelectResult()
        let lines = selectResponse.components(separatedBy: "\r\n")
        for line in lines {
            if line.contains(" NO ") || line.contains(" BAD ") {
                if line.contains("SELECT") || line.hasPrefix("A") {
                    throw IMAPError.folderNotFound(folder)
                }
            }
            
            // Parse EXISTS
            if line.contains("EXISTS") {
                if let match = line.range(of: #"\d+ EXISTS"#, options: .regularExpression) {
                    let numStr = line[match].replacingOccurrences(of: " EXISTS", with: "")
                    result.exists = Int(numStr) ?? 0
                }
            }
            
            // Parse RECENT
            if line.contains("RECENT") {
                if let match = line.range(of: #"\d+ RECENT"#, options: .regularExpression) {
                    let numStr = line[match].replacingOccurrences(of: " RECENT", with: "")
                    result.recent = Int(numStr) ?? 0
                }
            }
            
            // Parse UIDVALIDITY
            if line.contains("UIDVALIDITY") {
                if let match = line.range(of: #"UIDVALIDITY \d+"#, options: .regularExpression) {
                    let numStr = line[match].replacingOccurrences(of: "UIDVALIDITY ", with: "")
                    result.uidValidity = UInt32(numStr) ?? 0
                }
            }
            
            // Parse UIDNEXT
            if line.contains("UIDNEXT") {
                if let match = line.range(of: #"UIDNEXT \d+"#, options: .regularExpression) {
                    let numStr = line[match].replacingOccurrences(of: "UIDNEXT ", with: "")
                    result.uidNext = UInt32(numStr) ?? 0
                }
            }
            
            // Parse HIGHESTMODSEQ (CONDSTORE)
            if line.contains("HIGHESTMODSEQ") {
                if let match = line.range(of: #"HIGHESTMODSEQ \d+"#, options: .regularExpression) {
                    let numStr = line[match].replacingOccurrences(of: "HIGHESTMODSEQ ", with: "")
                    result.highestModSeq = UInt64(numStr) ?? 0
                }
            }
        }
        
        currentFolder = folder
        print("[IMAP] Selected '\(folder)': exists=\(result.exists), uidNext=\(result.uidNext), modSeq=\(result.highestModSeq)")
        return result
    }
    
    // MARK: - IMAP IDLE Support
    
    /// Start IDLE mode - call this after selecting a folder
    /// Returns immediately after sending IDLE command
    func startIdle() throws {
        guard supportsIdle else {
            throw IMAPError.invalidResponse("Server does not support IDLE")
        }
        guard currentFolder != nil else {
            throw IMAPError.invalidResponse("Must select a folder before IDLE")
        }
        guard !isIdling else {
            print("[IMAP] Already in IDLE mode")
            return
        }
        
        let tag = nextTag()
        idleTag = tag
        let command = "\(tag) IDLE\r\n"
        
        guard let data = command.data(using: .utf8),
              let outputStream = outputStream else {
            throw IMAPError.connectionFailed("Stream not available")
        }
        
        let bytesWritten = data.withUnsafeBytes { buffer in
            outputStream.write(buffer.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count)
        }
        
        if bytesWritten < 0 {
            throw IMAPError.connectionFailed("Failed to write IDLE command")
        }
        
        // Wait for continuation response "+ idling"
        let response = try readIdleResponse(timeout: 5)
        if response.contains("+") {
            isIdling = true
            print("[IMAP] IDLE mode started")
        } else {
            throw IMAPError.invalidResponse("IDLE failed: \(response)")
        }
    }
    
    /// Stop IDLE mode by sending DONE
    func stopIdle() throws {
        guard isIdling else {
            return
        }
        
        let command = "DONE\r\n"
        guard let data = command.data(using: .utf8),
              let outputStream = outputStream else {
            throw IMAPError.connectionFailed("Stream not available")
        }
        
        let bytesWritten = data.withUnsafeBytes { buffer in
            outputStream.write(buffer.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count)
        }
        
        if bytesWritten < 0 {
            throw IMAPError.connectionFailed("Failed to write DONE")
        }
        
        // Wait for tagged response
        if let tag = idleTag {
            _ = try? readResponse(untilTag: tag)
        }
        
        isIdling = false
        idleTag = nil
        print("[IMAP] IDLE mode stopped")
    }
    
    /// Check if there are any updates during IDLE (non-blocking)
    /// Returns notification type if something changed, nil if no update
    func checkIdleUpdate() -> IdleNotification? {
        guard isIdling, let inputStream = inputStream else {
            return nil
        }
        
        // Check if there's data available without blocking
        guard inputStream.hasBytesAvailable else {
            return nil
        }
        
        // Read available data
        var buffer = [UInt8](repeating: 0, count: 1024)
        let bytesRead = inputStream.read(&buffer, maxLength: buffer.count)
        
        guard bytesRead > 0 else {
            return nil
        }
        
        let response = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
        return parseIdleNotification(response)
    }
    
    /// Wait for IDLE notification with timeout
    /// Returns notification type or nil on timeout
    func waitForIdleUpdate(timeout: TimeInterval) -> IdleNotification? {
        guard isIdling else {
            return nil
        }
        
        do {
            let response = try readIdleResponse(timeout: timeout)
            return parseIdleNotification(response)
        } catch {
            return nil
        }
    }
    
    enum IdleNotification {
        case exists(Int)       // New message count
        case expunge(Int)      // Message deleted
        case recent(Int)       // New recent messages
        case fetch(Int)        // Flags changed
    }
    
    private func parseIdleNotification(_ response: String) -> IdleNotification? {
        let lines = response.components(separatedBy: "\r\n")
        for line in lines {
            // * 42 EXISTS - new message arrived
            if line.contains("EXISTS") {
                if let match = line.range(of: #"\* (\d+) EXISTS"#, options: .regularExpression) {
                    let numStr = line[match].replacingOccurrences(of: "* ", with: "")
                        .replacingOccurrences(of: " EXISTS", with: "")
                    if let count = Int(numStr) {
                        print("[IMAP] IDLE: EXISTS \(count)")
                        return .exists(count)
                    }
                }
            }
            
            // * 5 EXPUNGE - message removed
            if line.contains("EXPUNGE") {
                if let match = line.range(of: #"\* (\d+) EXPUNGE"#, options: .regularExpression) {
                    let numStr = line[match].replacingOccurrences(of: "* ", with: "")
                        .replacingOccurrences(of: " EXPUNGE", with: "")
                    if let seq = Int(numStr) {
                        print("[IMAP] IDLE: EXPUNGE \(seq)")
                        return .expunge(seq)
                    }
                }
            }
            
            // * 3 RECENT
            if line.contains("RECENT") && line.hasPrefix("*") {
                if let match = line.range(of: #"\* (\d+) RECENT"#, options: .regularExpression) {
                    let numStr = line[match].replacingOccurrences(of: "* ", with: "")
                        .replacingOccurrences(of: " RECENT", with: "")
                    if let count = Int(numStr) {
                        print("[IMAP] IDLE: RECENT \(count)")
                        return .recent(count)
                    }
                }
            }
            
            // * 42 FETCH (FLAGS ...)
            if line.contains("FETCH") && line.hasPrefix("*") {
                if let match = line.range(of: #"\* (\d+) FETCH"#, options: .regularExpression) {
                    let numStr = line[match].replacingOccurrences(of: "* ", with: "")
                        .replacingOccurrences(of: " FETCH", with: "")
                    if let seq = Int(numStr) {
                        print("[IMAP] IDLE: FETCH \(seq)")
                        return .fetch(seq)
                    }
                }
            }
        }
        return nil
    }
    
    private func readIdleResponse(timeout: TimeInterval) throws -> String {
        guard let inputStream = inputStream else {
            throw IMAPError.connectionFailed("Stream not available")
        }
        
        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
            if inputStream.hasBytesAvailable {
                let bytesRead = inputStream.read(&buffer, maxLength: buffer.count)
                if bytesRead > 0 {
                    responseData.append(contentsOf: buffer[0..<bytesRead])
                    // Check if we have a complete response
                    if let str = String(data: responseData, encoding: .utf8),
                       str.contains("\r\n") {
                        return str
                    }
                } else if bytesRead < 0 {
                    throw IMAPError.connectionFailed("Read error")
                }
            } else {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        
        throw IMAPError.timeout
    }
    
    // MARK: - CONDSTORE/QRESYNC Methods
    
    /// Fetch only emails that changed since a given MODSEQ
    func fetchChangedSince(folder: String, modSeq: UInt64, limit: Int = 100) throws -> (emails: [Email], deletedUIDs: [UInt32], newModSeq: UInt64) {
        guard supportsCondstore else {
            throw IMAPError.invalidResponse("Server does not support CONDSTORE")
        }
        
        let selectResult = try selectFolder(folder, forceReselect: true)
        
        // Use SEARCH MODSEQ to find changed messages
        let searchResponse = try sendCommand("UID SEARCH MODSEQ \(modSeq)")
        
        var changedUIDs: [UInt32] = []
        for line in searchResponse.components(separatedBy: "\r\n") {
            if line.hasPrefix("* SEARCH") {
                let parts = line.replacingOccurrences(of: "* SEARCH", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: " ")
                for part in parts {
                    // Skip the MODSEQ part if present in output
                    if let uid = UInt32(part) {
                        changedUIDs.append(uid)
                    }
                }
            }
        }
        
        // Limit the UIDs
        let uidsToFetch = Array(changedUIDs.suffix(limit))
        
        var emails: [Email] = []
        if !uidsToFetch.isEmpty {
            let uidSet = uidsToFetch.map { String($0) }.joined(separator: ",")
            emails = try fetchEmailsByUIDs(folder: folder, uids: uidSet)
        }
        
        print("[IMAP] CONDSTORE: \(changedUIDs.count) messages changed since modSeq \(modSeq)")
        
        return (emails: emails, deletedUIDs: [], newModSeq: selectResult.highestModSeq)
    }
    
    /// Fetch flag changes since MODSEQ (lighter than full fetch)
    func fetchFlagChanges(folder: String, modSeq: UInt64) throws -> [(uid: UInt32, flags: [String])] {
        guard supportsCondstore else {
            return []
        }
        
        _ = try selectFolder(folder)
        
        // FETCH all messages but only FLAGS, with CHANGEDSINCE
        let response = try sendCommand("UID FETCH 1:* (UID FLAGS) (CHANGEDSINCE \(modSeq))")
        
        var changes: [(uid: UInt32, flags: [String])] = []
        
        for line in response.components(separatedBy: "\r\n") {
            if line.contains("FETCH") && line.contains("FLAGS") {
                // Parse: * 5 FETCH (UID 123 FLAGS (\Seen \Flagged))
                var uid: UInt32 = 0
                var flags: [String] = []
                
                if let uidMatch = line.range(of: #"UID (\d+)"#, options: .regularExpression) {
                    let uidStr = line[uidMatch].replacingOccurrences(of: "UID ", with: "")
                    uid = UInt32(uidStr) ?? 0
                }
                
                if let flagsMatch = line.range(of: #"FLAGS \([^)]*\)"#, options: .regularExpression) {
                    let flagsStr = line[flagsMatch]
                        .replacingOccurrences(of: "FLAGS (", with: "")
                        .replacingOccurrences(of: ")", with: "")
                    flags = flagsStr.components(separatedBy: " ").filter { !$0.isEmpty }
                }
                
                if uid > 0 {
                    changes.append((uid: uid, flags: flags))
                }
            }
        }
        
        print("[IMAP] CONDSTORE: \(changes.count) flag changes since modSeq \(modSeq)")
        return changes
    }

    // MARK: - Delta Fetch (fetch only new emails since UID)
    
    /// Fetch emails by a comma-separated list of UIDs
    func fetchEmailsByUIDs(folder: String, uids: String) throws -> [Email] {
        try selectFolder(folder)
        let fetchResponse = try sendCommand("UID FETCH \(uids) (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID CONTENT-TYPE)])")
        return parseEmailsHeadersOnly(from: fetchResponse)
    }
    
    func fetchEmailsSince(folder: String, sinceUID: UInt32, limit: Int) throws -> [Email] {
        let fetchStart = Date()
        
        try selectFolder(folder)
        
        // Search for UIDs greater than the last known UID
        let searchResponse = try sendCommand("UID SEARCH UID \(sinceUID + 1):*")
        
        var uids: [UInt32] = []
        for line in searchResponse.components(separatedBy: "\r\n") {
            if line.hasPrefix("* SEARCH") {
                let parts = line.replacingOccurrences(of: "* SEARCH", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: " ")
                for part in parts {
                    if let uid = UInt32(part), uid > sinceUID {
                        uids.append(uid)
                    }
                }
            }
        }
        
        guard !uids.isEmpty else {
            print("[IMAP] No new messages since UID \(sinceUID)")
            return []
        }
        
        let recentUIDs = uids.suffix(limit)
        let uidList = recentUIDs.map { String($0) }.joined(separator: ",")
        print("[IMAP] Delta fetch: \(recentUIDs.count) new emails (UIDs: \(uidList.prefix(50))...)")
        
        let fetchResponse = try sendCommand("UID FETCH \(uidList) (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID CONTENT-TYPE)])")
        
        // Debug: show response 
        print("[IMAP] Delta fetch response length: \(fetchResponse.count) chars")
        print("[IMAP] Delta fetch response (first 3000): \(fetchResponse.prefix(3000))")
        
        let emails = parseEmailsHeadersOnly(from: fetchResponse)
        print("[IMAP] Delta fetch completed in \(Date().timeIntervalSince(fetchStart))s, parsed \(emails.count) emails")
        
        for email in emails {
            print("[IMAP] Delta email: UID=\(email.uid), from='\(email.from)', subject='\(email.subject.prefix(50))'")
        }
        
        return emails
    }

    func fetchEmails(folder: String, limit: Int, daysBack: Int = 0, searchQuery: String? = nil) throws -> [Email] {
        let fetchStart = Date()
        
        try selectFolder(folder)
        print("[IMAP] SELECT completed: \(Date().timeIntervalSince(fetchStart))s")

        // Build search command
        var searchCommand: String
        
        if let query = searchQuery, !query.isEmpty {
            // Use custom IMAP search query (server-side filtering!)
            searchCommand = "UID SEARCH \(query)"
            print("[IMAP] Using server-side search: \(query)")
        } else if daysBack > 0 {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "dd-MMM-yyyy"
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            let sinceDate = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
            let sinceDateStr = dateFormatter.string(from: sinceDate)
            searchCommand = "UID SEARCH SINCE \(sinceDateStr)"
        } else {
            searchCommand = "UID SEARCH ALL"
        }

        let searchResponse = try sendCommand(searchCommand)
        print("[IMAP] SEARCH completed: \(Date().timeIntervalSince(fetchStart))s")

        var uids: [UInt32] = []
        for line in searchResponse.components(separatedBy: "\r\n") {
            if line.hasPrefix("* SEARCH") {
                let parts = line.replacingOccurrences(of: "* SEARCH", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: " ")
                for part in parts {
                    if let uid = UInt32(part) {
                        uids.append(uid)
                    }
                }
            }
        }

        guard !uids.isEmpty else {
            print("[IMAP] No messages found")
            return []
        }
        
        print("[IMAP] Found \(uids.count) messages matching search")

        // Take the most recent N UIDs (highest UIDs = newest)
        let recentUIDs: [UInt32]
        if limit > 0 {
            recentUIDs = Array(uids.suffix(limit))
        } else {
            recentUIDs = uids
        }
        print("[IMAP] Fetching \(recentUIDs.count) emails (newest first)")

        // Sort descending so we fetch newest first
        let sortedUIDs = recentUIDs.sorted(by: >)

        let batchSize = 100  // Smaller batches for faster first render
        var allEmails: [Email] = []

        print("[IMAP] Starting batch fetch: \(sortedUIDs.count) emails in batches of \(batchSize)")

        for batchStart in stride(from: 0, to: sortedUIDs.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, sortedUIDs.count)
            let batchUIDs = Array(sortedUIDs[batchStart..<batchEnd])

            // Use comma-separated UIDs for precise fetching (ranges would include gaps)
            let uidList = batchUIDs.map { String($0) }.joined(separator: ",")

            print("[IMAP] Batch \(batchStart/batchSize + 1): fetching \(batchUIDs.count) emails (UIDs \(batchUIDs.first ?? 0)-\(batchUIDs.last ?? 0))")

            // Fetch only essential headers - MUCH faster than full HEADER
            let fetchCommand = "UID FETCH \(uidList) (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID CONTENT-TYPE)])"

            let fetchResponse = try sendCommand(fetchCommand)

            let batchEmails = parseEmailsHeadersOnly(from: fetchResponse)
            allEmails.append(contentsOf: batchEmails)
            print("[IMAP] Parsed: \(batchEmails.count) emails (total: \(allEmails.count))")
        }

        print("[IMAP] FETCH completed: \(Date().timeIntervalSince(fetchStart))s, total \(allEmails.count) emails")

        return allEmails
    }

    // MARK: - Parallel Streaming Fetch (multiple connections for speed)

    static func fetchEmailsParallel(
        config: IMAPConfig,
        folder: String,
        limit: Int,
        daysBack: Int = 0,
        searchQuery: String? = nil,
        shouldCancel: (() -> Bool)? = nil,  // Optional early termination check
        onBatch: @escaping ([Email]) -> Void,
        onComplete: @escaping (Error?) -> Void
    ) {
        let fetchStart = Date()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // First connection to get UIDs
                let searchConnection = IMAPConnection(config: config)
                try searchConnection.connect()
                try searchConnection.selectFolder(folder)

                // Build search command
                var searchCommand: String
                if let query = searchQuery, !query.isEmpty {
                    searchCommand = "UID SEARCH \(query)"
                } else if daysBack > 0 {
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "dd-MMM-yyyy"
                    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
                    let sinceDate = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
                    let sinceDateStr = dateFormatter.string(from: sinceDate)
                    searchCommand = "UID SEARCH SINCE \(sinceDateStr)"
                } else {
                    searchCommand = "UID SEARCH ALL"
                }

                let searchResponse = try searchConnection.sendCommand(searchCommand)
                searchConnection.disconnect()

                var uids: [UInt32] = []
                for line in searchResponse.components(separatedBy: "\r\n") {
                    if line.hasPrefix("* SEARCH") {
                        let parts = line.replacingOccurrences(of: "* SEARCH", with: "")
                            .trimmingCharacters(in: .whitespaces)
                            .split(separator: " ")
                        for part in parts {
                            if let uid = UInt32(part) {
                                uids.append(uid)
                            }
                        }
                    }
                }

                guard !uids.isEmpty else {
                    print("[IMAP] No messages found")
                    DispatchQueue.main.async { onComplete(nil) }
                    return
                }

                // Take most recent N, sorted newest first (hard cap at 300 to prevent memory issues)
                // Reduced from 500 to 300 to prevent OOM with large emails
                let maxFetch = min(limit > 0 ? limit : 300, 300)
                let recentUIDs = Array(uids.suffix(maxFetch).sorted(by: >))
                print("[IMAP] Parallel fetch: \(recentUIDs.count) emails (capped from \(uids.count), limit was \(limit))")

                // Split UIDs into chunks for parallel fetching
                let numConnections = 4
                let chunkSize = (recentUIDs.count + numConnections - 1) / numConnections
                var chunks: [[UInt32]] = []
                for i in stride(from: 0, to: recentUIDs.count, by: chunkSize) {
                    let end = min(i + chunkSize, recentUIDs.count)
                    chunks.append(Array(recentUIDs[i..<end]))
                }

                let group = DispatchGroup()
                let resultsLock = NSLock()
                var allErrors: [Error] = []

                // Fetch first chunk immediately on main path for fast first render
                if let firstChunk = chunks.first, !firstChunk.isEmpty {
                    let firstConnection = IMAPConnection(config: config)
                    defer { firstConnection.disconnect() }

                    try firstConnection.connect()
                    try firstConnection.selectFolder(folder)

                    let batchSize = 50
                    for batchStart in stride(from: 0, to: firstChunk.count, by: batchSize) {
                        // Check for early cancellation (e.g., 99+ unread reached)
                        if shouldCancel?() == true {
                            print("[IMAP] Thread 1: Early cancellation requested")
                            break
                        }
                        
                        // Use autoreleasepool to free memory after each batch
                        try autoreleasepool {
                            let batchEnd = min(batchStart + batchSize, firstChunk.count)
                            let batchUIDs = Array(firstChunk[batchStart..<batchEnd])
                            let uidList = batchUIDs.map { String($0) }.joined(separator: ",")

                            let fetchCommand = "UID FETCH \(uidList) (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID CONTENT-TYPE)])"
                            let fetchResponse = try firstConnection.sendCommand(fetchCommand)
                            let batchEmails = firstConnection.parseEmailsHeadersOnly(from: fetchResponse)

                            if !batchEmails.isEmpty {
                                onBatch(batchEmails)
                            }
                            print("[IMAP] Thread 1 batch: \(batchEmails.count) emails")
                        }
                    }
                }

                // Fetch remaining chunks in parallel (limit to 2 extra connections)
                // Skip if already cancelled
                let remainingChunks = shouldCancel?() == true ? [] : Array(chunks.dropFirst().prefix(2))
                for (index, chunk) in remainingChunks.enumerated() {
                    guard !chunk.isEmpty else { continue }

                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer { group.leave() }
                        
                        // Check for early cancellation before starting
                        if shouldCancel?() == true {
                            print("[IMAP] Thread \(index + 2): Skipped due to cancellation")
                            return
                        }

                        autoreleasepool {
                            let connection = IMAPConnection(config: config)
                            defer { connection.disconnect() }

                            do {
                                try connection.connect()
                                try connection.selectFolder(folder)

                                let uidList = chunk.map { String($0) }.joined(separator: ",")
                                let fetchCommand = "UID FETCH \(uidList) (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID CONTENT-TYPE)])"
                                let fetchResponse = try connection.sendCommand(fetchCommand)
                                let emails = connection.parseEmailsHeadersOnly(from: fetchResponse)

                                if !emails.isEmpty {
                                    onBatch(emails)
                                }
                                print("[IMAP] Thread \(index + 2): \(emails.count) emails")
                            } catch {
                                resultsLock.lock()
                                allErrors.append(error)
                                resultsLock.unlock()
                                print("[IMAP] Thread \(index + 2) error: \(error)")
                            }
                        }
                    }
                }

                // Wait with timeout to prevent deadlock
                let waitResult = group.wait(timeout: .now() + 120)
                if waitResult == .timedOut {
                    print("[IMAP] WARNING: Parallel fetch timed out after 120s")
                }

                print("[IMAP] Parallel fetch completed: \(Date().timeIntervalSince(fetchStart))s")
                DispatchQueue.main.async {
                    onComplete(allErrors.first)
                }

            } catch {
                print("[IMAP] Parallel fetch error: \(error)")
                DispatchQueue.main.async {
                    onComplete(error)
                }
            }
        }
    }

    func listFolders() throws -> [String] {
        let response = try sendCommand("LIST \"\" \"*\"")
        var folders: [String] = []

        let lines = response.components(separatedBy: "\r\n")
        for line in lines {
            if line.hasPrefix("* LIST") {
                guard let flagsEnd = line.range(of: ") ") else { continue }
                let afterFlags = String(line[flagsEnd.upperBound...])

                let parts = afterFlags.components(separatedBy: " ")
                guard parts.count >= 2 else { continue }

                let folderPart = parts.dropFirst().joined(separator: " ")

                var folderName = folderPart.trimmingCharacters(in: .whitespaces)

                if folderName.hasPrefix("\"") && folderName.hasSuffix("\"") {
                    folderName = String(folderName.dropFirst().dropLast())
                }

                if folderName.isEmpty || folderName == "/" || folderName == "." {
                    continue
                }

                let decoded = decodeModifiedUTF7(folderName)
                folders.append(decoded)
            }
        }

        return folders.sorted()
    }

    func markAsRead(folder: String, uid: UInt32) throws {
        try selectFolder(folder)
        let response = try sendCommand("UID STORE \(uid) +FLAGS (\\Seen)")
        if response.contains(" NO ") || response.contains(" BAD ") {
            throw IMAPError.fetchFailed("Failed to mark as read")
        }
    }

    func markAsUnread(folder: String, uid: UInt32) throws {
        try selectFolder(folder)
        let response = try sendCommand("UID STORE \(uid) -FLAGS (\\Seen)")
        if response.contains(" NO ") || response.contains(" BAD ") {
            throw IMAPError.fetchFailed("Failed to mark as unread")
        }
    }

    func deleteEmail(folder: String, uid: UInt32) throws {
        try selectFolder(folder)
        print("[IMAP] Deleting email UID \(uid) from \(folder)")
        let response = try sendCommand("UID STORE \(uid) +FLAGS (\\Deleted)")
        print("[IMAP] STORE response: \(response.prefix(200))")
        if response.contains(" NO ") || response.contains(" BAD ") {
            throw IMAPError.fetchFailed("Failed to delete email")
        }
        let expungeResponse = try sendCommand("EXPUNGE")
        print("[IMAP] EXPUNGE response: \(expungeResponse.prefix(200))")
        if expungeResponse.contains(" NO ") || expungeResponse.contains(" BAD ") {
            throw IMAPError.fetchFailed("Failed to expunge deleted email")
        }
        print("[IMAP] Delete completed for UID \(uid)")
    }

    func fetchFullMessage(folder: String, uid: UInt32) throws -> String {
        try selectFolder(folder)

        let response = try sendCommand("UID FETCH \(uid) (BODY.PEEK[])")

        if let bodyStart = response.range(of: "BODY[]") {
            let afterBody = response[bodyStart.upperBound...]
            if let _ = afterBody.range(of: "{"),
               let braceEnd = afterBody.range(of: "}") {
                let contentStart = afterBody.index(braceEnd.upperBound, offsetBy: 2, limitedBy: afterBody.endIndex) ?? braceEnd.upperBound
                var content = String(afterBody[contentStart...])

                if let closeIdx = content.range(of: ")\r\nA", options: .backwards) {
                    content = String(content[..<closeIdx.lowerBound])
                }

                return content
            }
        }

        return ""
    }
    
    // MARK: - NOOP for keep-alive
    
    func noop() throws {
        let response = try sendCommand("NOOP")
        if !response.contains("OK") {
            throw IMAPError.connectionFailed("NOOP failed")
        }
    }

    // MARK: - Modified UTF-7 Encoding

    private func encodeModifiedUTF7(_ string: String) -> String {
        var result = ""
        var nonAsciiBuffer = ""

        for char in string {
            if char == "&" {
                if !nonAsciiBuffer.isEmpty {
                    result += encodeUTF7Segment(nonAsciiBuffer)
                    nonAsciiBuffer = ""
                }
                result += "&-"
            } else if let ascii = char.asciiValue, ascii >= 0x20 && ascii <= 0x7E {
                if !nonAsciiBuffer.isEmpty {
                    result += encodeUTF7Segment(nonAsciiBuffer)
                    nonAsciiBuffer = ""
                }
                result.append(char)
            } else {
                nonAsciiBuffer.append(char)
            }
        }

        if !nonAsciiBuffer.isEmpty {
            result += encodeUTF7Segment(nonAsciiBuffer)
        }

        return result
    }

    private func encodeUTF7Segment(_ segment: String) -> String {
        var utf16Bytes: [UInt8] = []
        for scalar in segment.unicodeScalars {
            let value = scalar.value
            if value <= 0xFFFF {
                utf16Bytes.append(UInt8((value >> 8) & 0xFF))
                utf16Bytes.append(UInt8(value & 0xFF))
            } else {
                let adjusted = value - 0x10000
                let high = 0xD800 + ((adjusted >> 10) & 0x3FF)
                let low = 0xDC00 + (adjusted & 0x3FF)
                utf16Bytes.append(UInt8((high >> 8) & 0xFF))
                utf16Bytes.append(UInt8(high & 0xFF))
                utf16Bytes.append(UInt8((low >> 8) & 0xFF))
                utf16Bytes.append(UInt8(low & 0xFF))
            }
        }

        let base64 = Data(utf16Bytes).base64EncodedString()
            .replacingOccurrences(of: "/", with: ",")
            .replacingOccurrences(of: "=", with: "")

        return "&" + base64 + "-"
    }

    private func decodeModifiedUTF7(_ string: String) -> String {
        var result = ""
        var i = string.startIndex

        while i < string.endIndex {
            let char = string[i]

            if char == "&" {
                let nextIndex = string.index(after: i)
                if nextIndex < string.endIndex && string[nextIndex] == "-" {
                    result += "&"
                    i = string.index(after: nextIndex)
                } else {
                    if let dashIndex = string[nextIndex...].firstIndex(of: "-") {
                        let encoded = String(string[nextIndex..<dashIndex])
                        result += decodeUTF7Segment(encoded)
                        i = string.index(after: dashIndex)
                    } else {
                        result.append(char)
                        i = string.index(after: i)
                    }
                }
            } else {
                result.append(char)
                i = string.index(after: i)
            }
        }

        return result
    }

    private func decodeUTF7Segment(_ segment: String) -> String {
        var base64 = segment.replacingOccurrences(of: ",", with: "/")
        while base64.count % 4 != 0 {
            base64 += "="
        }

        guard let data = Data(base64Encoded: base64) else {
            return segment
        }

        var utf16: [UInt16] = []
        for i in stride(from: 0, to: data.count - 1, by: 2) {
            let value = UInt16(data[i]) << 8 | UInt16(data[i + 1])
            utf16.append(value)
        }

        return String(utf16CodeUnits: utf16, count: utf16.count)
    }

    private func nextTag() -> String {
        tagCounter += 1
        return "A\(String(format: "%04d", tagCounter))"
    }

    @discardableResult
    func sendCommand(_ command: String) throws -> String {
        guard isConnected || command.hasPrefix("LOGIN") || command == "LOGOUT" else {
            throw IMAPError.notConnected
        }
        
        let tag = nextTag()
        let fullCommand = "\(tag) \(command)\r\n"

        guard let data = fullCommand.data(using: .utf8),
              let outputStream = outputStream else {
            throw IMAPError.connectionFailed("Stream not available")
        }

        let bytesWritten = data.withUnsafeBytes { buffer in
            outputStream.write(buffer.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count)
        }

        if bytesWritten < 0 {
            connectionQueue.sync { _isConnected = false }
            throw IMAPError.connectionFailed("Failed to write to stream")
        }

        return try readResponse(untilTag: tag)
    }

    private func readResponse(untilTag tag: String? = nil) throws -> String {
        guard let inputStream = inputStream else {
            throw IMAPError.connectionFailed("Stream not available")
        }

        // Use Data for efficient appending (not String which is O(n²))
        var responseData = Data()
        responseData.reserveCapacity(32768)  // Pre-allocate smaller buffer

        let bufferSize = 16384  // Reduced from 32KB to 16KB
        let maxResponseSize = 5 * 1024 * 1024  // 5MB max (reduced from 10MB)
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let startTime = Date()

        let tagOK = tag.map { "\($0) OK".data(using: .utf8)! }
        let tagNO = tag.map { "\($0) NO".data(using: .utf8)! }
        let tagBAD = tag.map { "\($0) BAD".data(using: .utf8)! }
        let crlf = "\r\n".data(using: .utf8)!

        while true {
            if Date().timeIntervalSince(startTime) > timeout {
                connectionQueue.sync { _isConnected = false }
                throw IMAPError.timeout
            }

            // Prevent memory explosion
            if responseData.count > maxResponseSize {
                connectionQueue.sync { _isConnected = false }
                throw IMAPError.fetchFailed("Response too large (\(responseData.count) bytes)")
            }

            if inputStream.hasBytesAvailable {
                let bytesRead = inputStream.read(&buffer, maxLength: bufferSize)
                if bytesRead > 0 {
                    responseData.append(buffer, count: bytesRead)

                    // Check for completion
                    if let tagOK = tagOK, let tagNO = tagNO, let tagBAD = tagBAD {
                        // Check entire response for tag (handles both small and large responses)
                        if responseData.range(of: tagOK) != nil ||
                           responseData.range(of: tagNO) != nil ||
                           responseData.range(of: tagBAD) != nil {
                            break
                        }
                    } else {
                        // No tag specified - just wait for CRLF
                        if responseData.suffix(64).range(of: crlf) != nil {
                            break
                        }
                    }
                } else if bytesRead < 0 {
                    connectionQueue.sync { _isConnected = false }
                    throw IMAPError.connectionFailed("Read error")
                }
            } else {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }

        return String(data: responseData, encoding: .utf8)
            ?? String(data: responseData, encoding: .isoLatin1)
            ?? ""
    }

    private func parseEmailsHeadersOnly(from response: String) -> [Email] {
        var emails: [Email] = []
        
        // Parse FETCH responses by looking for "* N FETCH" patterns
        // Each FETCH may contain a literal {bytecount} followed by that many bytes of header data
        // We need to track these literals to avoid splitting in the wrong place
        
        var index = response.startIndex
        let endIndex = response.endIndex
        
        while index < endIndex {
            // Find next "* " that starts a FETCH response
            guard let starPos = response.range(of: "* ", range: index..<endIndex) else {
                break
            }
            
            // Check if this is a FETCH response
            let lineStart = starPos.lowerBound
            guard let lineEnd = response.range(of: "\r\n", range: lineStart..<endIndex) else {
                break
            }
            
            let firstLine = String(response[lineStart..<lineEnd.lowerBound])
            
            // Skip if not a FETCH
            if !firstLine.contains("FETCH") {
                index = lineEnd.upperBound
                continue
            }
            
            // Check for literal {bytecount}
            var blockEnd = lineEnd.upperBound
            if let literalMatch = firstLine.range(of: #"\{(\d+)\}$"#, options: .regularExpression) {
                let bytecountStr = firstLine[literalMatch]
                    .dropFirst() // {
                    .dropLast() // }
                if let bytecount = Int(bytecountStr) {
                    // Skip past the literal data
                    let literalStart = lineEnd.upperBound
                    let literalEnd = response.index(literalStart, offsetBy: bytecount, limitedBy: endIndex) ?? endIndex
                    
                    // Find the closing parenthesis after the literal
                    if let closeParen = response.range(of: ")\r\n", range: literalEnd..<endIndex) {
                        blockEnd = closeParen.upperBound
                    } else if let closeParen = response.range(of: ")", range: literalEnd..<endIndex) {
                        blockEnd = closeParen.upperBound
                    } else {
                        blockEnd = literalEnd
                    }
                }
            }
            
            // Extract the full block
            let block = String(response[lineStart..<blockEnd])
            
            if let email = parseEmailHeaderOnly(block) {
                emails.append(email)
            }
            
            index = blockEnd
        }

        return emails
    }

    private func parseEmailHeaderOnly(_ block: String) -> Email? {
        // Parse UID
        var uid: UInt32 = 0
        if let uidMatch = block.range(of: #"UID (\d+)"#, options: .regularExpression) {
            let uidStr = String(block[uidMatch]).replacingOccurrences(of: "UID ", with: "")
            uid = UInt32(uidStr) ?? 0
        }
        
        guard uid > 0 else { return nil }

        // Parse FLAGS
        var isRead = false
        if let flagsMatch = block.range(of: #"FLAGS \([^)]*\)"#, options: .regularExpression) {
            let flags = String(block[flagsMatch])
            isRead = flags.contains("\\Seen")
        }

        // Parse INTERNALDATE
        var receivedDate = Date()
        if let internalDateMatch = block.range(of: #"INTERNALDATE "([^"]+)""#, options: .regularExpression) {
            let dateStr = String(block[internalDateMatch])
                .replacingOccurrences(of: "INTERNALDATE \"", with: "")
                .replacingOccurrences(of: "\"", with: "")
            if let parsed = parseInternalDate(dateStr) {
                receivedDate = parsed
            }
        }

        // Simple approach: scan all lines in block for header patterns
        // Headers are lines like "From: ...", "Subject: ...", etc.
        var subject = ""
        var from = ""
        var to = ""
        var contentType = "text/plain"
        var boundary = ""
        
        let lines = block.components(separatedBy: "\r\n")
        var currentHeader = ""
        var inHeaders = false
        
        for line in lines {
            // Start parsing headers after we see the literal {bytecount}
            if !inHeaders {
                if line.contains("{") && line.hasSuffix("}") {
                    inHeaders = true
                }
                continue
            }
            
            // Stop at empty line or closing paren
            if line.isEmpty || line == ")" || line.hasPrefix(")") {
                // Process last header
                if !currentHeader.isEmpty {
                    parseHeaderLine(currentHeader, subject: &subject, from: &from, to: &to, contentType: &contentType, boundary: &boundary)
                }
                break
            }
            
            // Header continuation (starts with space/tab)
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                currentHeader += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                // New header - process previous one first
                if !currentHeader.isEmpty {
                    parseHeaderLine(currentHeader, subject: &subject, from: &from, to: &to, contentType: &contentType, boundary: &boundary)
                }
                currentHeader = line
            }
        }

        // Parse from field into name and email components
        let fromDisplay = from.isEmpty ? "Unknown Sender" : from
        let parsedFrom = Email.parseFromField(fromDisplay)

        return Email(
            id: "\(uid)",
            uid: uid,
            subject: subject.isEmpty ? "No Subject" : subject,
            from: fromDisplay,
            fromEmail: parsedFrom.email,
            fromName: parsedFrom.name,
            to: to,
            date: receivedDate,  // Use INTERNALDATE (receive date) for sorting!
            preview: "",
            body: "",
            contentType: contentType,
            boundary: boundary,
            isRead: isRead
        )
    }

    private func parseInternalDate(_ dateStr: String) -> Date? {
        // INTERNALDATE format: "31-Dec-2025 12:34:56 +0000"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: dateStr)
    }

    private func parseHeaderLine(_ line: String, subject: inout String, from: inout String, to: inout String, contentType: inout String, boundary: inout String) {
        let lower = line.lowercased()
        
        if lower.hasPrefix("subject:") {
            subject = decodeHeader(String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces))
        } else if lower.hasPrefix("from:") {
            from = parseFromHeader(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        } else if lower.hasPrefix("to:") {
            to = parseFromHeader(String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces))
        } else if lower.hasPrefix("content-type:") {
            let ct = String(line.dropFirst(13)).trimmingCharacters(in: .whitespaces)
            contentType = ct
            if let boundaryRange = ct.range(of: #"boundary="?([^";\s]+)"?"#, options: .regularExpression) {
                var b = String(ct[boundaryRange])
                b = b.replacingOccurrences(of: "boundary=", with: "")
                b = b.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                boundary = b
            }
        }
    }
    
    private func parseFromHeader(_ from: String) -> String {
        let decoded = decodeHeader(from)

        if let angleStart = decoded.firstIndex(of: "<") {
            let name = String(decoded[..<angleStart]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                return name.replacingOccurrences(of: "\"", with: "")
            }
        }

        return decoded.replacingOccurrences(of: "\"", with: "")
    }

    private func decodeHeader(_ header: String) -> String {
        var result = header

        let pattern = #"=\?([^?]+)\?([BQ])\?([^?]+)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return header
        }

        var matches = regex.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result))

        while !matches.isEmpty {
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result),
                      let charsetRange = Range(match.range(at: 1), in: result),
                      let encodingRange = Range(match.range(at: 2), in: result),
                      let dataRange = Range(match.range(at: 3), in: result) else { continue }

                let charset = String(result[charsetRange]).lowercased()
                let encoding = String(result[encodingRange]).uppercased()
                let encodedData = String(result[dataRange])

                var decoded: String?
                let stringEncoding = charsetToEncoding(charset)

                if encoding == "B" {
                    if let data = Data(base64Encoded: encodedData) {
                        decoded = String(data: data, encoding: stringEncoding) ?? String(data: data, encoding: .utf8)
                    }
                } else if encoding == "Q" {
                    decoded = decodeQuotedPrintableHeader(encodedData, encoding: stringEncoding)
                }

                if let decoded = decoded {
                    result.replaceSubrange(fullRange, with: decoded)
                }
            }

            matches = regex.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result))
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    private func charsetToEncoding(_ charset: String) -> String.Encoding {
        switch charset.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "iso-8859-1", "latin1": return .isoLatin1
        case "iso-8859-2": return .isoLatin2
        case "windows-1252", "cp1252": return .windowsCP1252
        case "us-ascii", "ascii": return .ascii
        default: return .utf8
        }
    }

    private func decodeQuotedPrintableHeader(_ string: String, encoding: String.Encoding) -> String {
        var bytes: [UInt8] = []
        var i = string.startIndex

        while i < string.endIndex {
            let char = string[i]
            if char == "_" {
                bytes.append(0x20)
            } else if char == "=" {
                let nextIdx = string.index(after: i)
                if nextIdx < string.endIndex,
                   let endIdx = string.index(nextIdx, offsetBy: 2, limitedBy: string.endIndex) {
                    let hex = String(string[nextIdx..<endIdx])
                    if let byte = UInt8(hex, radix: 16) {
                        bytes.append(byte)
                        i = endIdx
                        continue
                    }
                }
                bytes.append(UInt8(ascii: "="))
            } else if let ascii = char.asciiValue {
                bytes.append(ascii)
            }
            i = string.index(after: i)
        }

        return String(bytes: bytes, encoding: encoding) ?? String(bytes: bytes, encoding: .utf8) ?? string
    }

    private func parseDate(_ dateString: String) -> Date? {
        let cleanDate = dateString.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        let formatters = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss z",
            "dd MMM yyyy HH:mm:ss z",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss ZZZZ",
            "dd MMM yyyy HH:mm:ss ZZZZ"
        ]

        for format in formatters {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: cleanDate) {
                return date
            }
        }

        return nil
    }
}
