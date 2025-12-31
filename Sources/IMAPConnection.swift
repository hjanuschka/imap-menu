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
        let response = try sendCommand("LOGIN \"\(config.username)\" \"\(config.password)\"")
        if !response.contains("OK") {
            throw IMAPError.authenticationFailed
        }
    }
    
    // MARK: - Optimized Folder Selection
    
    private func selectFolder(_ folder: String) throws {
        // Skip if already selected
        if currentFolder == folder {
            print("[IMAP] Folder '\(folder)' already selected, skipping SELECT")
            return
        }
        
        let encodedFolder = encodeModifiedUTF7(folder)
        let selectResponse = try sendCommand("SELECT \"\(encodedFolder)\"")
        
        let lines = selectResponse.components(separatedBy: "\r\n")
        for line in lines {
            if line.contains(" NO ") || line.contains(" BAD ") {
                if line.contains("SELECT") || line.hasPrefix("A") {
                    throw IMAPError.folderNotFound(folder)
                }
            }
        }
        
        currentFolder = folder
    }

    // MARK: - Delta Fetch (fetch only new emails since UID)
    
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
        
        let fetchResponse = try sendCommand("UID FETCH \(uidList) (UID FLAGS BODY.PEEK[HEADER])")
        
        let emails = parseEmailsHeadersOnly(from: fetchResponse)
        print("[IMAP] Delta fetch completed in \(Date().timeIntervalSince(fetchStart))s")
        
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

        // If limit is 0, fetch all; otherwise take the most recent N
        let recentUIDs: ArraySlice<UInt32>
        if limit > 0 {
            recentUIDs = uids.suffix(limit)
        } else {
            recentUIDs = uids[...]
        }
        let uidList = recentUIDs.map { String($0) }.joined(separator: ",")
        print("[IMAP] Fetching \(recentUIDs.count) emails")

        let fetchResponse = try sendCommand("UID FETCH \(uidList) (UID FLAGS BODY.PEEK[HEADER])")
        print("[IMAP] FETCH completed: \(Date().timeIntervalSince(fetchStart))s")

        let emails = parseEmailsHeadersOnly(from: fetchResponse)
        print("[IMAP] Parsing completed: \(Date().timeIntervalSince(fetchStart))s")

        return emails
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
        let response = try sendCommand("UID STORE \(uid) +FLAGS (\\Deleted)")
        if response.contains(" NO ") || response.contains(" BAD ") {
            throw IMAPError.fetchFailed("Failed to delete email")
        }
        let expungeResponse = try sendCommand("EXPUNGE")
        if expungeResponse.contains(" NO ") || expungeResponse.contains(" BAD ") {
            throw IMAPError.fetchFailed("Failed to expunge deleted email")
        }
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
    private func sendCommand(_ command: String) throws -> String {
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

        var response = ""
        let bufferSize = 16384
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let startTime = Date()

        while true {
            if Date().timeIntervalSince(startTime) > timeout {
                connectionQueue.sync { _isConnected = false }
                throw IMAPError.timeout
            }

            if inputStream.hasBytesAvailable {
                let bytesRead = inputStream.read(&buffer, maxLength: bufferSize)
                if bytesRead > 0 {
                    if let chunk = String(bytes: buffer[0..<bytesRead], encoding: .utf8) {
                        response += chunk
                    } else if let chunk = String(bytes: buffer[0..<bytesRead], encoding: .isoLatin1) {
                        response += chunk
                    }

                    if let tag = tag {
                        if response.contains("\(tag) OK") || response.contains("\(tag) NO") || response.contains("\(tag) BAD") {
                            break
                        }
                    } else {
                        if response.contains("\r\n") {
                            break
                        }
                    }
                } else if bytesRead < 0 {
                    connectionQueue.sync { _isConnected = false }
                    throw IMAPError.connectionFailed("Read error")
                }
            } else {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        return response
    }

    private func parseEmailsHeadersOnly(from response: String) -> [Email] {
        var emails: [Email] = []
        let blocks = response.components(separatedBy: "* ").filter { $0.contains("FETCH") }

        for block in blocks {
            if let email = parseEmailHeaderOnly(block) {
                emails.append(email)
            }
        }

        return emails
    }

    private func parseEmailHeaderOnly(_ block: String) -> Email? {
        var uid: UInt32 = 0
        if let uidMatch = block.range(of: #"UID (\d+)"#, options: .regularExpression) {
            let uidStr = String(block[uidMatch]).replacingOccurrences(of: "UID ", with: "")
            uid = UInt32(uidStr) ?? 0
        }

        var isRead = false
        if let flagsMatch = block.range(of: #"FLAGS \([^)]*\)"#, options: .regularExpression) {
            let flags = String(block[flagsMatch])
            isRead = flags.contains("\\Seen")
        }

        var subject = ""
        var from = ""
        var to = ""
        var date = Date()
        var contentType = "text/plain"
        var boundary = ""

        if let headerMarker = block.range(of: "BODY[HEADER]") {
            let afterMarker = block[headerMarker.upperBound...]

            if let _ = afterMarker.range(of: "{"),
               let braceEnd = afterMarker.range(of: "}") {
                let afterBrace = afterMarker[braceEnd.upperBound...]
                var headers = String(afterBrace)

                if headers.hasPrefix("\r\n") {
                    headers = String(headers.dropFirst(2))
                }

                let headerLines = headers.components(separatedBy: "\r\n")
                var currentHeader = ""

                for line in headerLines {
                    if line.isEmpty || line == ")" || line.hasPrefix(")") {
                        break
                    }

                    if line.hasPrefix(" ") || line.hasPrefix("\t") {
                        currentHeader += " " + line.trimmingCharacters(in: .whitespaces)
                    } else {
                        if !currentHeader.isEmpty {
                            processHeader(currentHeader, subject: &subject, from: &from, to: &to, date: &date, contentType: &contentType, boundary: &boundary)
                        }
                        currentHeader = line
                    }
                }
                if !currentHeader.isEmpty {
                    processHeader(currentHeader, subject: &subject, from: &from, to: &to, date: &date, contentType: &contentType, boundary: &boundary)
                }
            }
        }

        guard uid > 0 else { return nil }

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
            date: date,
            preview: "",
            body: "",
            contentType: contentType,
            boundary: boundary,
            isRead: isRead
        )
    }

    private func processHeader(_ header: String, subject: inout String, from: inout String, to: inout String, date: inout Date, contentType: inout String, boundary: inout String) {
        let lower = header.lowercased()

        if lower.hasPrefix("subject:") {
            subject = decodeHeader(String(header.dropFirst(8)).trimmingCharacters(in: .whitespaces))
        } else if lower.hasPrefix("from:") {
            from = parseFromHeader(String(header.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        } else if lower.hasPrefix("to:") {
            to = parseFromHeader(String(header.dropFirst(3)).trimmingCharacters(in: .whitespaces))
        } else if lower.hasPrefix("date:") {
            date = parseDate(String(header.dropFirst(5)).trimmingCharacters(in: .whitespaces)) ?? Date()
        } else if lower.hasPrefix("content-type:") {
            let ct = String(header.dropFirst(13)).trimmingCharacters(in: .whitespaces)
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
