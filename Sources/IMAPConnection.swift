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

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .authenticationFailed: return "Authentication failed"
        case .folderNotFound(let folder): return "Folder not found: \(folder)"
        case .fetchFailed(let msg): return "Fetch failed: \(msg)"
        case .invalidResponse(let msg): return "Invalid response: \(msg)"
        case .timeout: return "Connection timeout"
        case .noMessages: return "No messages in folder"
        }
    }
}

class IMAPConnection {
    private let config: IMAPConfig
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var tagCounter = 0
    private let timeout: TimeInterval = 30

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
        print("[IMAP] Streams created: \(Date().timeIntervalSince(connectStart))s")

        if config.useSSL {
            inputStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
            outputStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)

            let sslSettings: [String: Any] = [
                kCFStreamSSLValidatesCertificateChain as String: true
            ]
            inputStream.setProperty(sslSettings, forKey: kCFStreamPropertySSLSettings as Stream.PropertyKey)
            outputStream.setProperty(sslSettings, forKey: kCFStreamPropertySSLSettings as Stream.PropertyKey)
        }

        print("[IMAP] Opening streams...")
        inputStream.open()
        outputStream.open()

        let startTime = Date()
        while inputStream.streamStatus != .open || outputStream.streamStatus != .open {
            if Date().timeIntervalSince(startTime) > timeout {
                print("[IMAP] Timeout! Input: \(inputStream.streamStatus.rawValue), Output: \(outputStream.streamStatus.rawValue)")
                throw IMAPError.timeout
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        print("[IMAP] Streams open: \(Date().timeIntervalSince(connectStart))s")

        print("[IMAP] Reading server greeting...")
        _ = try readResponse()
        print("[IMAP] Greeting received: \(Date().timeIntervalSince(connectStart))s")

        print("[IMAP] Logging in...")
        try login()
        print("[IMAP] Login complete: \(Date().timeIntervalSince(connectStart))s")
    }

    func disconnect() {
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

    func fetchEmails(folder: String, limit: Int, daysBack: Int = 20) throws -> [Email] {
        let fetchStart = Date()
        let encodedFolder = encodeModifiedUTF7(folder)
        print("[IMAP] SELECT folder: \(encodedFolder)")
        let selectResponse = try sendCommand("SELECT \"\(encodedFolder)\"")
        print("[IMAP] SELECT completed: \(Date().timeIntervalSince(fetchStart))s")

        let lines = selectResponse.components(separatedBy: "\r\n")
        var hasError = false

        for line in lines {
            if line.contains(" NO ") || line.contains(" BAD ") {
                if line.contains("SELECT") || line.hasPrefix("A") {
                    hasError = true
                }
            }
        }

        if hasError {
            throw IMAPError.folderNotFound(folder)
        }

        // Search for emails from the last N days
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MMM-yyyy"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let sinceDate = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
        let sinceDateStr = dateFormatter.string(from: sinceDate)

        print("[IMAP] SEARCH SINCE \(sinceDateStr)")
        let searchResponse = try sendCommand("UID SEARCH SINCE \(sinceDateStr)")
        print("[IMAP] SEARCH completed: \(Date().timeIntervalSince(fetchStart))s")

        // Parse UIDs from search response
        // Format: * SEARCH 123 456 789 ...
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
            print("[IMAP] No messages found in last \(daysBack) days")
            return []
        }

        // Take the most recent ones (last N UIDs)
        let recentUIDs = uids.suffix(limit)
        let uidList = recentUIDs.map { String($0) }.joined(separator: ",")
        print("[IMAP] Fetching \(recentUIDs.count) emails (UIDs: \(uidList.prefix(50))...)")

        // Fetch only headers initially - body will be loaded on demand
        let fetchResponse = try sendCommand("UID FETCH \(uidList) (UID FLAGS BODY.PEEK[HEADER])")
        print("[IMAP] FETCH completed: \(Date().timeIntervalSince(fetchStart))s, response size: \(fetchResponse.count) bytes")

        print("[IMAP] Parsing emails...")
        let emails = parseEmailsHeadersOnly(from: fetchResponse)
        print("[IMAP] Parsing completed: \(Date().timeIntervalSince(fetchStart))s")

        return emails
    }

    func listFolders() throws -> [String] {
        let response = try sendCommand("LIST \"\" \"*\"")
        var folders: [String] = []

        let lines = response.components(separatedBy: "\r\n")
        for line in lines {
            // Match lines like: * LIST (\HasNoChildren) "/" "FolderName"
            // or: * LIST (\HasNoChildren) "/" INBOX
            if line.hasPrefix("* LIST") {
                // Find delimiter and folder name after it
                // Format: * LIST (flags) "delimiter" "foldername" or * LIST (flags) "delimiter" foldername

                // Find the closing paren of flags
                guard let flagsEnd = line.range(of: ") ") else { continue }
                let afterFlags = String(line[flagsEnd.upperBound...])

                // afterFlags is now: "/" "FolderName" or "/" INBOX or "." "Folder.Name"
                let parts = afterFlags.components(separatedBy: " ")
                guard parts.count >= 2 else { continue }

                // Skip the delimiter (first part), get folder name (rest)
                let folderPart = parts.dropFirst().joined(separator: " ")

                var folderName = folderPart.trimmingCharacters(in: .whitespaces)

                // Remove surrounding quotes if present
                if folderName.hasPrefix("\"") && folderName.hasSuffix("\"") {
                    folderName = String(folderName.dropFirst().dropLast())
                }

                // Skip empty or delimiter-only entries
                if folderName.isEmpty || folderName == "/" || folderName == "." {
                    continue
                }

                // Decode modified UTF-7
                let decoded = decodeModifiedUTF7(folderName)
                folders.append(decoded)
            }
        }

        return folders.sorted()
    }

    func markAsRead(folder: String, uid: UInt32) throws {
        let encodedFolder = encodeModifiedUTF7(folder)
        _ = try sendCommand("SELECT \"\(encodedFolder)\"")
        let response = try sendCommand("UID STORE \(uid) +FLAGS (\\Seen)")
        if response.contains(" NO ") || response.contains(" BAD ") {
            throw IMAPError.fetchFailed("Failed to mark as read")
        }
    }

    func markAsUnread(folder: String, uid: UInt32) throws {
        let encodedFolder = encodeModifiedUTF7(folder)
        _ = try sendCommand("SELECT \"\(encodedFolder)\"")
        let response = try sendCommand("UID STORE \(uid) -FLAGS (\\Seen)")
        if response.contains(" NO ") || response.contains(" BAD ") {
            throw IMAPError.fetchFailed("Failed to mark as unread")
        }
    }

    func deleteEmail(folder: String, uid: UInt32) throws {
        let encodedFolder = encodeModifiedUTF7(folder)
        _ = try sendCommand("SELECT \"\(encodedFolder)\"")
        // Mark as deleted
        let response = try sendCommand("UID STORE \(uid) +FLAGS (\\Deleted)")
        if response.contains(" NO ") || response.contains(" BAD ") {
            throw IMAPError.fetchFailed("Failed to delete email")
        }
        // Expunge to permanently remove
        let expungeResponse = try sendCommand("EXPUNGE")
        if expungeResponse.contains(" NO ") || expungeResponse.contains(" BAD ") {
            throw IMAPError.fetchFailed("Failed to expunge deleted email")
        }
    }

    func fetchFullMessage(folder: String, uid: UInt32) throws -> String {
        let encodedFolder = encodeModifiedUTF7(folder)
        _ = try sendCommand("SELECT \"\(encodedFolder)\"")

        // Fetch the complete message body
        let response = try sendCommand("UID FETCH \(uid) (BODY.PEEK[])")

        print("[IMAP] fetchFullMessage response length: \(response.count)")

        // Extract the body from the response
        // Format: * N FETCH (UID X BODY[] {size}\r\n<content>)\r\n
        if let bodyStart = response.range(of: "BODY[]") {
            let afterBody = response[bodyStart.upperBound...]
            if let braceStart = afterBody.range(of: "{"),
               let braceEnd = afterBody.range(of: "}") {
                // Get size
                let sizeStr = String(afterBody[braceStart.upperBound..<braceEnd.lowerBound])
                print("[IMAP] Body size from header: \(sizeStr)")

                // Content starts after }\r\n
                let contentStart = afterBody.index(braceEnd.upperBound, offsetBy: 2, limitedBy: afterBody.endIndex) ?? braceEnd.upperBound
                var content = String(afterBody[contentStart...])

                // Remove trailing IMAP response
                if let closeIdx = content.range(of: ")\r\nA", options: .backwards) {
                    content = String(content[..<closeIdx.lowerBound])
                }

                print("[IMAP] Full message content length: \(content.count)")
                return content
            }
        }

        return ""
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
                    throw IMAPError.connectionFailed("Read error")
                }
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        return response
    }

    private func parseEmails(from response: String) -> [Email] {
        var emails: [Email] = []
        let blocks = response.components(separatedBy: "* ").filter { $0.contains("FETCH") }

        for block in blocks {
            if let email = parseEmailBlock(block) {
                emails.append(email)
            }
        }

        return emails
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
        // Extract UID
        var uid: UInt32 = 0
        if let uidMatch = block.range(of: #"UID (\d+)"#, options: .regularExpression) {
            let uidStr = String(block[uidMatch]).replacingOccurrences(of: "UID ", with: "")
            uid = UInt32(uidStr) ?? 0
        }

        // Extract flags
        var isRead = false
        if let flagsMatch = block.range(of: #"FLAGS \([^)]*\)"#, options: .regularExpression) {
            let flags = String(block[flagsMatch])
            isRead = flags.contains("\\Seen")
        }

        // Extract headers
        var subject = ""
        var from = ""
        var date = Date()
        var contentType = "text/plain"
        var boundary = ""

        // Find BODY[HEADER] section - look for the size in braces, then content after
        // Format: BODY[HEADER] {1234}\r\n<headers>
        if let headerMarker = block.range(of: "BODY[HEADER]") {
            let afterMarker = block[headerMarker.upperBound...]

            // Find the opening brace with size
            if let braceStart = afterMarker.range(of: "{"),
               let braceEnd = afterMarker.range(of: "}") {
                // Content starts after }\r\n
                let afterBrace = afterMarker[braceEnd.upperBound...]
                var headers = String(afterBrace)

                // Skip the \r\n after the brace
                if headers.hasPrefix("\r\n") {
                    headers = String(headers.dropFirst(2))
                }

                // Parse headers line by line
                let headerLines = headers.components(separatedBy: "\r\n")
                var currentHeader = ""

                for line in headerLines {
                    // Stop if we hit end of headers (empty line or closing paren)
                    if line.isEmpty || line == ")" || line.hasPrefix(")") {
                        break
                    }

                    if line.hasPrefix(" ") || line.hasPrefix("\t") {
                        // Continuation of previous header
                        currentHeader += " " + line.trimmingCharacters(in: .whitespaces)
                    } else {
                        // Process previous header and start new one
                        if !currentHeader.isEmpty {
                            processHeader(currentHeader, subject: &subject, from: &from, date: &date, contentType: &contentType, boundary: &boundary)
                        }
                        currentHeader = line
                    }
                }
                // Process last header
                if !currentHeader.isEmpty {
                    processHeader(currentHeader, subject: &subject, from: &from, date: &date, contentType: &contentType, boundary: &boundary)
                }
            }
        }

        guard uid > 0 else { return nil }

        return Email(
            id: "\(uid)",
            uid: uid,
            subject: subject.isEmpty ? "No Subject" : subject,
            from: from.isEmpty ? "Unknown Sender" : from,
            date: date,
            preview: "", // No preview - body loaded on demand
            body: "",    // Body loaded on demand
            contentType: contentType,
            boundary: boundary,
            isRead: isRead
        )
    }

    private func parseEmailBlock(_ block: String) -> Email? {
        // Extract UID
        var uid: UInt32 = 0
        if let uidMatch = block.range(of: #"UID (\d+)"#, options: .regularExpression) {
            let uidStr = String(block[uidMatch]).replacingOccurrences(of: "UID ", with: "")
            uid = UInt32(uidStr) ?? 0
        }

        // Extract flags
        var isRead = false
        if let flagsMatch = block.range(of: #"FLAGS \([^)]*\)"#, options: .regularExpression) {
            let flags = String(block[flagsMatch])
            isRead = flags.contains("\\Seen")
        }

        // Extract headers
        var subject = ""
        var from = ""
        var date = Date()
        var contentType = "text/plain"
        var boundary = ""

        // Find BODY[HEADER] section
        if let headerStart = block.range(of: "BODY[HEADER]") {
            let afterHeader = block[headerStart.upperBound...]
            if let braceEnd = afterHeader.range(of: "}") {
                let headerContent = String(afterHeader[braceEnd.upperBound...])
                let headerEnd = headerContent.range(of: "BODY[TEXT]")?.lowerBound ?? headerContent.endIndex
                let headers = String(headerContent[..<headerEnd])

                // Parse headers
                let headerLines = headers.components(separatedBy: "\r\n")
                var currentHeader = ""

                for line in headerLines {
                    if line.hasPrefix(" ") || line.hasPrefix("\t") {
                        // Continuation of previous header
                        currentHeader += " " + line.trimmingCharacters(in: .whitespaces)
                    } else {
                        // Process previous header
                        processHeader(currentHeader, subject: &subject, from: &from, date: &date, contentType: &contentType, boundary: &boundary)
                        currentHeader = line
                    }
                }
                processHeader(currentHeader, subject: &subject, from: &from, date: &date, contentType: &contentType, boundary: &boundary)
            }
        }

        // Extract body
        var body = ""
        if let bodyMarker = block.range(of: "BODY[TEXT]") {
            let afterMarker = block[bodyMarker.upperBound...]
            if let braceEnd = afterMarker.range(of: "}") {
                var bodyContent = String(afterMarker[braceEnd.upperBound...])
                // Clean up trailing IMAP stuff
                if let closeIdx = bodyContent.range(of: ")\r\nA") {
                    bodyContent = String(bodyContent[..<closeIdx.lowerBound])
                }
                body = bodyContent
            }
        }

        // Create preview using MIMEParser
        let preview = MIMEParser.createPreview(from: body, boundary: boundary)

        guard uid > 0 else { return nil }

        return Email(
            id: "\(uid)",
            uid: uid,
            subject: subject.isEmpty ? "No Subject" : subject,
            from: from.isEmpty ? "Unknown Sender" : from,
            date: date,
            preview: preview,
            body: body,
            contentType: contentType,
            boundary: boundary,
            isRead: isRead
        )
    }

    private func processHeader(_ header: String, subject: inout String, from: inout String, date: inout Date, contentType: inout String, boundary: inout String) {
        let lower = header.lowercased()

        if lower.hasPrefix("subject:") {
            subject = decodeHeader(String(header.dropFirst(8)).trimmingCharacters(in: .whitespaces))
        } else if lower.hasPrefix("from:") {
            from = parseFromHeader(String(header.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        } else if lower.hasPrefix("date:") {
            date = parseDate(String(header.dropFirst(5)).trimmingCharacters(in: .whitespaces)) ?? Date()
        } else if lower.hasPrefix("content-type:") {
            let ct = String(header.dropFirst(13)).trimmingCharacters(in: .whitespaces)
            contentType = ct
            // Extract boundary if multipart
            if let boundaryRange = ct.range(of: #"boundary="?([^";\s]+)"?"#, options: .regularExpression) {
                var b = String(ct[boundaryRange])
                b = b.replacingOccurrences(of: "boundary=", with: "")
                b = b.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                boundary = b
            }
        }
    }

    private func parseFromHeader(_ from: String) -> String {
        var decoded = decodeHeader(from)

        // Try to extract display name from "Name <email>" format
        if let angleStart = decoded.firstIndex(of: "<") {
            let name = String(decoded[..<angleStart]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                return name.replacingOccurrences(of: "\"", with: "")
            }
        }

        // Just return decoded email
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

            // Check for more encoded words
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
                bytes.append(0x20) // space
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
