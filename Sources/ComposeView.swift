import SwiftUI

enum ComposeMode {
    case new
    case reply(Email)
    case replyAll(Email)
}

struct ComposeView: View {
    let account: IMAPAccount
    let mode: ComposeMode
    let onDismiss: () -> Void
    let onSent: () -> Void

    @State private var toField: String = ""
    @State private var ccField: String = ""
    @State private var bccField: String = ""
    @State private var subjectField: String = ""
    @State private var messageBody: String = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var showCc = false
    @State private var showBcc = false

    init(account: IMAPAccount, mode: ComposeMode, onDismiss: @escaping () -> Void, onSent: @escaping () -> Void) {
        self.account = account
        self.mode = mode
        self.onDismiss = onDismiss
        self.onSent = onSent

        // Initialize state based on mode
        switch mode {
        case .new:
            break
        case .reply(let email):
            _toField = State(initialValue: formatReplyAddress(name: email.fromName, email: email.fromEmail, fallback: email.from))
            _subjectField = State(initialValue: email.subject.hasPrefix("Re:") ? email.subject : "Re: \(email.subject)")
            _messageBody = State(initialValue: buildQuotedReply(email: email, signature: account.signature))
        case .replyAll(let email):
            _toField = State(initialValue: formatReplyAddress(name: email.fromName, email: email.fromEmail, fallback: email.from))
            _ccField = State(initialValue: extractCcRecipients(email: email, excludeEmail: account.emailAddress))
            _subjectField = State(initialValue: email.subject.hasPrefix("Re:") ? email.subject : "Re: \(email.subject)")
            _messageBody = State(initialValue: buildQuotedReply(email: email, signature: account.signature))
            _showCc = State(initialValue: true)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(modeTitle)
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.escape)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Form
            VStack(spacing: 12) {
                // From (read-only)
                HStack {
                    Text("From:")
                        .frame(width: 60, alignment: .trailing)
                        .foregroundColor(.secondary)
                    Text(account.emailAddress)
                        .foregroundColor(.primary)
                    Spacer()
                }

                // To
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("To:")
                            .frame(width: 60, alignment: .trailing)
                            .foregroundColor(.secondary)
                        TextField("recipient@example.com", text: $toField)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Spacer().frame(width: 64)
                        Text("Separate multiple addresses with commas")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                // CC (toggle)
                if showCc || !ccField.isEmpty {
                    HStack {
                        Text("Cc:")
                            .frame(width: 60, alignment: .trailing)
                            .foregroundColor(.secondary)
                        TextField("cc1@example.com, cc2@example.com", text: $ccField)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                
                // BCC (toggle)
                if showBcc || !bccField.isEmpty {
                    HStack {
                        Text("Bcc:")
                            .frame(width: 60, alignment: .trailing)
                            .foregroundColor(.secondary)
                        TextField("bcc@example.com", text: $bccField)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                
                // Show Cc/Bcc buttons if not already shown
                if !showCc || !showBcc {
                    HStack {
                        Spacer()
                            .frame(width: 64)
                        if !showCc && ccField.isEmpty {
                            Button("Add Cc") {
                                showCc = true
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                            .font(.caption)
                        }
                        if !showBcc && bccField.isEmpty {
                            Button("Add Bcc") {
                                showBcc = true
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                            .font(.caption)
                        }
                        Spacer()
                    }
                }

                // Subject
                HStack {
                    Text("Subject:")
                        .frame(width: 60, alignment: .trailing)
                        .foregroundColor(.secondary)
                    TextField("Subject", text: $subjectField)
                        .textFieldStyle(.roundedBorder)
                }

                Divider()

                // Body
                TextEditor(text: $messageBody)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .border(Color.secondary.opacity(0.2))
            }
            .padding()

            Divider()

            // Footer
            HStack {
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                Spacer()

                if isSending {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 8)
                }

                Button("Send") {
                    sendEmail()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isSending || toField.isEmpty || subjectField.isEmpty)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 550, height: 500)
    }

    private var modeTitle: String {
        switch mode {
        case .new:
            return "New Message"
        case .reply:
            return "Reply"
        case .replyAll:
            return "Reply All"
        }
    }

    private func sendEmail() {
        guard account.hasSmtpConfigured else {
            errorMessage = "SMTP not configured. Go to Settings to set up SMTP."
            return
        }

        isSending = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let config = SMTPConfig(
                    host: account.smtpHost,
                    port: account.smtpPort,
                    username: account.effectiveSmtpUsername,
                    password: account.effectiveSmtpPassword,
                    useSSL: account.smtpUseSSL,
                    fromEmail: account.emailAddress,
                    fromName: account.displayName
                )

                let connection = SMTPConnection(config: config)
                try connection.connect()

                // Get threading headers for replies
                var inReplyTo: String?
                var references: String?

                switch mode {
                case .reply(let email), .replyAll(let email):
                    inReplyTo = "<\(email.id)@mail>"
                    references = "<\(email.id)@mail>"
                case .new:
                    break
                }

                try connection.sendEmail(
                    to: toField,
                    cc: ccField,
                    bcc: bccField,
                    subject: subjectField,
                    body: messageBody,
                    inReplyTo: inReplyTo,
                    references: references
                )

                connection.disconnect()

                DispatchQueue.main.async {
                    isSending = false
                    onSent()
                    onDismiss()
                }
            } catch {
                DispatchQueue.main.async {
                    isSending = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// Helper function to format reply address with both name and email
private func formatReplyAddress(name: String, email: String, fallback: String) -> String {
    if email.isEmpty {
        return fallback
    }
    if name.isEmpty || name == email {
        return email
    }
    return "\(name) <\(email)>"
}

// Helper functions for building replies
private func buildQuotedReply(email: Email, signature: String) -> String {
    var reply = "\n\n"

    // Add signature if present
    if !signature.isEmpty {
        reply += "--\n\(signature)\n\n"
    }

    // Add quote header
    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .medium
    dateFormatter.timeStyle = .short
    let dateString = dateFormatter.string(from: email.date)

    reply += "On \(dateString), \(email.from) wrote:\n"

    // Quote the original message
    let originalBody = extractPlainTextFromEmail(email)
    let quotedLines = originalBody.components(separatedBy: "\n").map { "> \($0)" }
    reply += quotedLines.joined(separator: "\n")

    return reply
}

private func extractPlainTextFromEmail(_ email: Email) -> String {
    // If we have the body, parse it
    if !email.body.isEmpty {
        // Try to extract plain text from the body
        let parser = MIMEParser(body: email.body, contentType: email.contentType, boundary: email.boundary)
        let html = parser.getHTMLContent()

        // Strip HTML tags for plain text reply
        let stripped = html
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "</p>", with: "\n")
            .replacingOccurrences(of: "</div>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")

        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Fallback to preview
    return email.preview
}

private func extractCcRecipients(email: Email, excludeEmail: String) -> String {
    // Parse the To field to extract additional recipients
    var recipients: [String] = []

    // Add original To recipients (excluding the current user and sender)
    let toRecipients = email.to.components(separatedBy: ",")
    for recipient in toRecipients {
        let trimmed = recipient.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty &&
           !trimmed.lowercased().contains(excludeEmail.lowercased()) &&
           !trimmed.lowercased().contains(email.fromEmail.lowercased()) {
            recipients.append(trimmed)
        }
    }

    return recipients.joined(separator: ", ")
}

// Window helper for presenting compose view
class ComposeWindowController {
    private var window: NSWindow?

    func showCompose(account: IMAPAccount, mode: ComposeMode, onSent: @escaping () -> Void) {
        let composeView = ComposeView(
            account: account,
            mode: mode,
            onDismiss: { [weak self] in
                self?.close()
            },
            onSent: onSent
        )

        let hostingController = NSHostingController(rootView: composeView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Compose"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 550, height: 500))
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }

    func close() {
        window?.close()
        window = nil
    }
}
