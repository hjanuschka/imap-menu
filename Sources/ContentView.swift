import SwiftUI
import WebKit

struct ContentView: View {
    @ObservedObject var emailManager: EmailManager
    @State private var selectedEmail: Email?
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Emails")
                    .font(.headline)
                Spacer()
                if emailManager.unreadCount > 0 {
                    Text("\(emailManager.unreadCount) unread")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Countdown timer
                Text("\(emailManager.secondsUntilRefresh)s")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 30)

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
            } else if emailManager.emails.isEmpty && !emailManager.isLoading {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No emails in folder")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(emailManager.emails) { email in
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
        .frame(width: 420, height: 550)
        .background(Color.white)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}

struct EmailRowView: View {
    @ObservedObject var emailManager: EmailManager
    let emailId: String
    let isSelected: Bool

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

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isSelected ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isSelected)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.white)
            .contentShape(Rectangle())
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

    // Get the current email state from the manager
    private var currentEmail: Email {
        emailManager.emails.first(where: { $0.id == email.id }) ?? email
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Action buttons
            HStack(spacing: 12) {
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
                    .frame(height: 200)
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
