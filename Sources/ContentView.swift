import SwiftUI
import WebKit

struct ContentView: View {
    @ObservedObject var emailManager: EmailManager
    @State private var selectedEmail: Email?
    @State private var showingSettings = false
    @State private var searchText = ""
    @State private var isSearching = false
    
    private var filteredEmails: [Email] {
        if searchText.isEmpty {
            return emailManager.emails
        }
        let lowercased = searchText.lowercased()
        return emailManager.emails.filter { email in
            email.subject.lowercased().contains(lowercased) ||
            email.from.lowercased().contains(lowercased) ||
            email.fromName.lowercased().contains(lowercased) ||
            email.preview.lowercased().contains(lowercased)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if isSearching {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search emails...", text: $searchText)
                            .textFieldStyle(.plain)
                        Button(action: {
                            searchText = ""
                            isSearching = false
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                } else {
                    Text("Emails")
                        .font(.headline)
                    
                    Button(action: {
                        isSearching = true
                    }) {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.plain)
                }
                
                Spacer()
                if emailManager.unreadCount > 0 && !isSearching {
                    Text("\(emailManager.unreadCount) unread")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Countdown timer or IDLE indicator
                if emailManager.secondsUntilRefresh < 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                        Text("IDLE")
                    }
                    .font(.caption)
                    .foregroundColor(.green)
                    .help("Real-time push notifications active")
                } else {
                    Text("\(emailManager.secondsUntilRefresh)s")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 30)
                }

                // Show fetch progress
                if !emailManager.fetchProgress.isEmpty {
                    Text(emailManager.fetchProgress)
                        .font(.caption2)
                        .foregroundColor(.blue)
                }

                Spacer()

                Button(action: {
                    emailManager.refresh()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(emailManager.isLoading ? 360 : 0))
                        .animation(emailManager.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: emailManager.isLoading)
                }
                .buttonStyle(.plain)

                Button(action: {
                    showingSettings = true
                }) {
                    Image(systemName: "gear")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Content
            if let error = emailManager.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Configure IMAP") {
                        showingSettings = true
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                .background(Color.white)
            } else if filteredEmails.isEmpty && !emailManager.isLoading {
                VStack(spacing: 12) {
                    Image(systemName: searchText.isEmpty ? "tray" : "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(searchText.isEmpty ? "No emails in folder" : "No emails match '\(searchText)'")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
            } else {
                // Show email list with inline detail
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredEmails) { email in
                            EmailRowView(emailManager: emailManager, emailId: email.id, isSelected: selectedEmail?.id == email.id)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        if selectedEmail?.id == email.id {
                                            selectedEmail = nil
                                        } else {
                                            selectedEmail = email
                                        }
                                    }
                                }

                            if selectedEmail?.id == email.id {
                                EmailDetailView(email: email, emailManager: emailManager, selectedEmail: $selectedEmail)
                                    .frame(height: 300)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            Divider()
                                .padding(.leading, 12)
                        }
                    }
                }
                .background(Color.white)
            }

            Divider()

            // Footer
            HStack {
                Circle()
                    .fill(emailManager.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(emailManager.isConnected ? "Connected" : "Disconnected")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if let lastSync = emailManager.lastSyncTime {
                    Text("• \(lastSyncFormatted(lastSync))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
    
    private func lastSyncFormatted(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 {
            return "synced \(seconds)s ago"
        } else if seconds < 3600 {
            return "synced \(seconds / 60)m ago"
        } else {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "synced at \(formatter.string(from: date))"
        }
    }
}

struct EmailRowView: View {
    @ObservedObject var emailManager: EmailManager
    let emailId: String
    let isSelected: Bool
    @State private var isHovering = false

    private var email: Email? {
        emailManager.emails.first(where: { $0.id == emailId })
    }

    var body: some View {
        if let email = email {
            HStack(alignment: .top, spacing: 10) {
                // Unread indicator
                Circle()
                    .fill(email.isRead ? Color.clear : Color.accentColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(email.from)
                            .font(.system(size: 13, weight: email.isRead ? .regular : .semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(formatDate(email.date))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text(email.subject)
                        .font(.system(size: 12, weight: email.isRead ? .regular : .medium))
                        .lineLimit(2)
                        .foregroundColor(email.isRead ? .secondary : .primary)

                    if !email.preview.isEmpty && !isSelected {
                        Text(email.preview)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Action buttons (always visible)
                HStack(spacing: 4) {
                    Button(action: {
                        if email.isRead {
                            emailManager.markAsUnread(email)
                        } else {
                            emailManager.markAsRead(email)
                        }
                    }) {
                        Image(systemName: email.isRead ? "envelope.badge" : "envelope.open")
                            .font(.system(size: 11))
                            .foregroundColor(email.isRead ? .orange : .blue)
                    }
                    .buttonStyle(.plain)
                    .help(email.isRead ? "Mark as Unread" : "Mark as Read")

                    Button(action: {
                        emailManager.deleteEmail(email)
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
            .contextMenu {
                Button(action: {
                    if email.isRead {
                        emailManager.markAsUnread(email)
                    } else {
                        emailManager.markAsRead(email)
                    }
                }) {
                    Label(email.isRead ? "Mark as Unread" : "Mark as Read",
                          systemImage: email.isRead ? "envelope.badge" : "envelope.open")
                }

                Button(role: .destructive, action: {
                    emailManager.deleteEmail(email)
                }) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }
}

struct EmailDetailView: View {
    let email: Email
    @ObservedObject var emailManager: EmailManager
    @Binding var selectedEmail: Email?
    @State private var fullBodyHTML: String = ""
    @State private var isLoading: Bool = true
    @State private var showDeleteConfirm: Bool = false
    @State private var markAsReadTimer: Timer?
    @State private var composeWindowController: ComposeWindowController?

    // Get the current email state from the manager
    private var currentEmail: Email {
        emailManager.emails.first(where: { $0.id == email.id }) ?? email
    }

    private var canReply: Bool {
        emailManager.account.hasSmtpConfigured
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Action buttons
            HStack(spacing: 12) {
                // Reply buttons
                Button(action: {
                    openReply(mode: .reply(currentEmail))
                }) {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canReply)
                .help(canReply ? "Reply to sender" : "Configure SMTP in Settings to reply")

                Button(action: {
                    openReply(mode: .replyAll(currentEmail))
                }) {
                    Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canReply)
                .help(canReply ? "Reply to all recipients" : "Configure SMTP in Settings to reply")

                Divider()
                    .frame(height: 20)

                Button(action: {
                    // Cancel any pending mark-as-read timer
                    markAsReadTimer?.invalidate()
                    markAsReadTimer = nil

                    if currentEmail.isRead {
                        emailManager.markAsUnread(currentEmail)
                    } else {
                        emailManager.markAsRead(currentEmail)
                    }
                }) {
                    Label(currentEmail.isRead ? "Mark Unread" : "Mark Read",
                          systemImage: currentEmail.isRead ? "envelope.badge" : "envelope.open")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: {
                    showDeleteConfirm = true
                }) {
                    Label("Delete", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Email content
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(height: 200)
            } else {
                WebViewRepresentable(html: fullBodyHTML)
            }
        }
        .background(Color.white)
        .onAppear {
            loadFullBody()
            startMarkAsReadTimer()
        }
        .onDisappear {
            markAsReadTimer?.invalidate()
            markAsReadTimer = nil
        }
        .alert("Delete Email?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                selectedEmail = nil
                emailManager.deleteEmail(email)
            }
        } message: {
            Text("This will permanently delete the email.")
        }
    }

    private func startMarkAsReadTimer() {
        // Only start timer if email is unread
        guard !currentEmail.isRead else { return }

        markAsReadTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            // Check again if still unread (user might have manually toggled)
            if let email = emailManager.emails.first(where: { $0.id == self.email.id }), !email.isRead {
                emailManager.markAsRead(email)
            }
        }
    }

    private func loadFullBody() {
        emailManager.fetchFullBody(for: email) { body in
            if body.isEmpty {
                self.fullBodyHTML = email.getHTMLBody()
            } else {
                let parser = MIMEParser(body: body, contentType: email.contentType, boundary: email.boundary)
                self.fullBodyHTML = parser.getHTMLContent()
            }
            self.isLoading = false
        }
    }

    private func openReply(mode: ComposeMode) {
        // Store the email body in the email for quoting
        var emailWithBody = currentEmail
        if !fullBodyHTML.isEmpty {
            // Create an email with the loaded body for proper quoting
            emailWithBody = Email(
                id: currentEmail.id,
                uid: currentEmail.uid,
                subject: currentEmail.subject,
                from: currentEmail.from,
                fromEmail: currentEmail.fromEmail,
                fromName: currentEmail.fromName,
                to: currentEmail.to,
                date: currentEmail.date,
                preview: currentEmail.preview,
                body: fullBodyHTML,
                contentType: "text/html",
                boundary: "",
                isRead: currentEmail.isRead
            )
        }

        let controller = ComposeWindowController()
        let replyMode: ComposeMode
        switch mode {
        case .reply:
            replyMode = .reply(emailWithBody)
        case .replyAll:
            replyMode = .replyAll(emailWithBody)
        case .new:
            replyMode = .new
        }

        controller.showCompose(account: emailManager.account, mode: replyMode) {
            // Email sent successfully - could show notification here
            debugLog("[Compose] Email sent successfully")
        }
        composeWindowController = controller
    }
}

// WKWebView wrapper for SwiftUI
struct WebViewRepresentable: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Add base styling if the HTML doesn't have it
        var styledHTML = html

        if !html.lowercased().contains("<html") {
            styledHTML = wrapWithStyle(html)
        } else if !html.lowercased().contains("<style") {
            // Inject style into existing HTML
            styledHTML = injectStyle(html)
        }

        webView.loadHTMLString(styledHTML, baseURL: nil)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // If it's a link click, open in system browser
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url {
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }
    }

    private func wrapWithStyle(_ content: String) -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                \(baseStyle)
            </style>
        </head>
        <body>\(content)</body>
        </html>
        """
    }

    private func injectStyle(_ html: String) -> String {
        let styleTag = "<style>\(baseStyle)</style>"

        if let headEnd = html.range(of: "</head>", options: .caseInsensitive) {
            var modified = html
            modified.insert(contentsOf: styleTag, at: headEnd.lowerBound)
            return modified
        }

        return html
    }

    private var baseStyle: String {
        """
        :root {
            color-scheme: light dark;
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
            font-size: 12px;
            line-height: 1.5;
            color: #333;
            background: white;
            margin: 0;
            padding: 12px;
            word-wrap: break-word;
        }
        @media (prefers-color-scheme: dark) {
            body {
                color: #e0e0e0;
                background: #1e1e1e;
            }
            a { color: #6cb6ff; }
            pre, code {
                background: #2d2d2d;
            }
            blockquote {
                border-left-color: #555;
                color: #aaa;
            }
        }
        img { max-width: 100%; height: auto; }
        a { color: #007AFF; }
        pre, code {
            background: #f5f5f5;
            padding: 2px 6px;
            border-radius: 3px;
            font-size: 11px;
        }
        blockquote {
            border-left: 3px solid #ddd;
            margin: 8px 0;
            padding-left: 12px;
            color: #666;
        }
        table { border-collapse: collapse; max-width: 100%; }
        td, th { padding: 4px 8px; }
        """
    }
}
