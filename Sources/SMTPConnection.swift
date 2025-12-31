import Foundation

enum SMTPError: Error, LocalizedError {
    case connectionFailed(String)
    case authenticationFailed
    case sendFailed(String)
    case timeout
    case notConnected
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .authenticationFailed: return "SMTP authentication failed"
        case .sendFailed(let msg): return "Failed to send: \(msg)"
        case .timeout: return "Connection timeout"
        case .notConnected: return "Not connected to SMTP server"
        case .invalidResponse(let msg): return "Invalid response: \(msg)"
        }
    }
}

struct SMTPConfig {
    var host: String
    var port: Int
    var username: String
    var password: String
    var useSSL: Bool
    var fromEmail: String
    var fromName: String
}

class SMTPConnection {
    private let config: SMTPConfig
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private let timeout: TimeInterval = 30
    private var isConnected = false

    init(config: SMTPConfig) {
        self.config = config
    }

    func connect() throws {
        print("[SMTP] Connecting to \(config.host):\(config.port)")

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
            throw SMTPError.connectionFailed("Failed to create streams")
        }

        self.inputStream = inputStream
        self.outputStream = outputStream

        // For port 465, use implicit SSL
        // For port 587, use STARTTLS after connection
        if config.useSSL && config.port == 465 {
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
                throw SMTPError.timeout
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        // Read greeting
        let greeting = try readResponse()
        print("[SMTP] Greeting: \(greeting.prefix(50))")
        guard greeting.hasPrefix("220") else {
            throw SMTPError.connectionFailed("Invalid greeting: \(greeting)")
        }

        // Send EHLO
        let ehloResponse = try sendCommand("EHLO localhost")
        print("[SMTP] EHLO response received")

        // STARTTLS for port 587 if SSL is enabled
        if config.useSSL && config.port == 587 && ehloResponse.contains("STARTTLS") {
            let starttlsResponse = try sendCommand("STARTTLS")
            guard starttlsResponse.hasPrefix("220") else {
                throw SMTPError.connectionFailed("STARTTLS failed: \(starttlsResponse)")
            }

            // Upgrade to TLS
            inputStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
            outputStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)

            let sslSettings: [String: Any] = [
                kCFStreamSSLValidatesCertificateChain as String: true
            ]
            inputStream.setProperty(sslSettings, forKey: kCFStreamPropertySSLSettings as Stream.PropertyKey)
            outputStream.setProperty(sslSettings, forKey: kCFStreamPropertySSLSettings as Stream.PropertyKey)

            // Send EHLO again after STARTTLS
            _ = try sendCommand("EHLO localhost")
            print("[SMTP] TLS established")
        }

        // Authenticate
        try authenticate()

        isConnected = true
        print("[SMTP] Connected and authenticated")
    }

    private func authenticate() throws {
        // Try AUTH PLAIN first (most common)
        let authString = "\0\(config.username)\0\(config.password)"
        guard let authData = authString.data(using: .utf8) else {
            throw SMTPError.authenticationFailed
        }
        let base64Auth = authData.base64EncodedString()

        let authResponse = try sendCommand("AUTH PLAIN \(base64Auth)")
        if authResponse.hasPrefix("235") {
            return
        }

        // Try AUTH LOGIN as fallback
        let loginResponse = try sendCommand("AUTH LOGIN")
        if loginResponse.hasPrefix("334") {
            guard let usernameData = config.username.data(using: .utf8),
                  let passwordData = config.password.data(using: .utf8) else {
                throw SMTPError.authenticationFailed
            }

            let userResponse = try sendCommand(usernameData.base64EncodedString())
            if !userResponse.hasPrefix("334") {
                throw SMTPError.authenticationFailed
            }

            let passResponse = try sendCommand(passwordData.base64EncodedString())
            if !passResponse.hasPrefix("235") {
                throw SMTPError.authenticationFailed
            }
            return
        }

        throw SMTPError.authenticationFailed
    }

    func disconnect() {
        if isConnected {
            _ = try? sendCommand("QUIT")
        }
        inputStream?.close()
        outputStream?.close()
        inputStream = nil
        outputStream = nil
        isConnected = false
    }

    func sendEmail(to: String, cc: String = "", subject: String, body: String, inReplyTo: String? = nil, references: String? = nil) throws {
        guard isConnected else {
            throw SMTPError.notConnected
        }

        // MAIL FROM
        let mailFromResponse = try sendCommand("MAIL FROM:<\(config.fromEmail)>")
        guard mailFromResponse.hasPrefix("250") else {
            throw SMTPError.sendFailed("MAIL FROM failed: \(mailFromResponse)")
        }

        // RCPT TO - primary recipient
        let recipients = parseRecipients(to)
        for recipient in recipients {
            let rcptResponse = try sendCommand("RCPT TO:<\(recipient)>")
            guard rcptResponse.hasPrefix("250") else {
                throw SMTPError.sendFailed("RCPT TO failed for \(recipient): \(rcptResponse)")
            }
        }

        // RCPT TO - CC recipients
        if !cc.isEmpty {
            let ccRecipients = parseRecipients(cc)
            for recipient in ccRecipients {
                let rcptResponse = try sendCommand("RCPT TO:<\(recipient)>")
                guard rcptResponse.hasPrefix("250") else {
                    throw SMTPError.sendFailed("RCPT TO (CC) failed for \(recipient): \(rcptResponse)")
                }
            }
        }

        // DATA
        let dataResponse = try sendCommand("DATA")
        guard dataResponse.hasPrefix("354") else {
            throw SMTPError.sendFailed("DATA failed: \(dataResponse)")
        }

        // Build message
        var message = ""
        message += "From: \(formatAddress(config.fromName, config.fromEmail))\r\n"
        message += "To: \(to)\r\n"
        if !cc.isEmpty {
            message += "Cc: \(cc)\r\n"
        }
        message += "Subject: \(encodeSubject(subject))\r\n"
        message += "Date: \(formatDate())\r\n"
        message += "Message-ID: <\(UUID().uuidString)@\(config.host)>\r\n"
        message += "MIME-Version: 1.0\r\n"
        message += "Content-Type: text/plain; charset=UTF-8\r\n"
        message += "Content-Transfer-Encoding: 8bit\r\n"

        // Add threading headers for replies
        if let replyTo = inReplyTo {
            message += "In-Reply-To: \(replyTo)\r\n"
        }
        if let refs = references {
            message += "References: \(refs)\r\n"
        }

        message += "\r\n"
        message += body
        message += "\r\n.\r\n"

        // Send message content
        guard let messageData = message.data(using: .utf8),
              let outputStream = outputStream else {
            throw SMTPError.sendFailed("Failed to encode message")
        }

        let bytesWritten = messageData.withUnsafeBytes { buffer in
            outputStream.write(buffer.bindMemory(to: UInt8.self).baseAddress!, maxLength: messageData.count)
        }

        if bytesWritten < 0 {
            throw SMTPError.sendFailed("Failed to write message")
        }

        // Read final response
        let finalResponse = try readResponse()
        guard finalResponse.hasPrefix("250") else {
            throw SMTPError.sendFailed("Message rejected: \(finalResponse)")
        }

        print("[SMTP] Email sent successfully")
    }

    private func parseRecipients(_ recipients: String) -> [String] {
        // Parse "Name <email>, Name2 <email2>" or "email1, email2" format
        var emails: [String] = []

        let parts = recipients.components(separatedBy: ",")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if let angleStart = trimmed.firstIndex(of: "<"),
               let angleEnd = trimmed.firstIndex(of: ">") {
                let email = String(trimmed[trimmed.index(after: angleStart)..<angleEnd])
                if !email.isEmpty {
                    emails.append(email)
                }
            } else if trimmed.contains("@") {
                emails.append(trimmed)
            }
        }

        return emails
    }

    private func formatAddress(_ name: String, _ email: String) -> String {
        if name.isEmpty {
            return email
        }
        // Encode name if it contains special characters
        if name.contains(where: { !$0.isASCII || "\"\\".contains($0) }) {
            return "=?UTF-8?B?\(Data(name.utf8).base64EncodedString())?= <\(email)>"
        }
        return "\"\(name)\" <\(email)>"
    }

    private func encodeSubject(_ subject: String) -> String {
        // Encode subject if it contains non-ASCII characters
        if subject.contains(where: { !$0.isASCII }) {
            return "=?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?="
        }
        return subject
    }

    private func formatDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    @discardableResult
    private func sendCommand(_ command: String) throws -> String {
        guard let outputStream = outputStream else {
            throw SMTPError.notConnected
        }

        let fullCommand = command + "\r\n"
        guard let data = fullCommand.data(using: .utf8) else {
            throw SMTPError.sendFailed("Failed to encode command")
        }

        let bytesWritten = data.withUnsafeBytes { buffer in
            outputStream.write(buffer.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count)
        }

        if bytesWritten < 0 {
            throw SMTPError.connectionFailed("Failed to write to stream")
        }

        return try readResponse()
    }

    private func readResponse() throws -> String {
        guard let inputStream = inputStream else {
            throw SMTPError.notConnected
        }

        var response = ""
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let startTime = Date()

        while true {
            if Date().timeIntervalSince(startTime) > timeout {
                throw SMTPError.timeout
            }

            if inputStream.hasBytesAvailable {
                let bytesRead = inputStream.read(&buffer, maxLength: bufferSize)
                if bytesRead > 0 {
                    if let chunk = String(bytes: buffer[0..<bytesRead], encoding: .utf8) {
                        response += chunk
                    }

                    // SMTP responses end with \r\n and status code
                    // Multi-line responses have - after code, final line has space
                    let lines = response.components(separatedBy: "\r\n")
                    if let lastLine = lines.dropLast().last, lastLine.count >= 4 {
                        let index = lastLine.index(lastLine.startIndex, offsetBy: 3)
                        if lastLine[index] == " " {
                            break
                        }
                    }
                } else if bytesRead < 0 {
                    throw SMTPError.connectionFailed("Read error")
                }
            } else {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
