import SwiftUI
import WebKit

// MARK: - Main Content View

struct ContentView: View {
    @ObservedObject var emailManager: EmailManager
    @State private var selectedEmail: Email?
    @State private var showingSettings = false
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var composeWindowController: ComposeWindowController?
    
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
            // Content
            if selectedEmail != nil {
                EmailDetailView(email: selectedEmail!, emailManager: emailManager, selectedEmail: $selectedEmail)
            } else {
                // Header (only show in list view)
                headerView
                
                Divider()
                    .opacity(0.3)
                
                emailListView
            }
            
            Divider()
                .opacity(0.3)
            
            // Footer
            footerView
        }
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
    
    // MARK: - Header View
    
    private var headerView: some View {
        HStack(spacing: 12) {
            if isSearching {
                searchField
            } else {
                // Folder name
                Text(emailManager.folderConfig.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                
                // Search button
                Button(action: { isSearching = true }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                
                // Compose button (if SMTP configured)
                if emailManager.account.hasSmtpConfigured {
                    Button(action: { openCompose() }) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 12))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Compose new email")
                }
                
                Spacer()
                
                // Unread badge
                if emailManager.unreadCount > 0 {
                    Text("\(emailManager.unreadCount)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.blue))
                }
                
                // Status indicator
                statusIndicator
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
    
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            
            TextField("Search emails...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            
            Button(action: {
                searchText = ""
                isSearching = false
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.05))
        .cornerRadius(8)
    }
    
    private var statusIndicator: some View {
        Group {
            if emailManager.secondsUntilRefresh < 0 {
                // IDLE mode - real-time
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("Live")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .help("Real-time push notifications active")
            } else {
                // Polling mode
                Text("\(emailManager.secondsUntilRefresh)s")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Compose
    
    private func openCompose() {
        let controller = ComposeWindowController()
        controller.showCompose(account: emailManager.account, mode: .new) {
            debugLog("[Compose] Email sent successfully")
        }
        composeWindowController = controller
    }
    
    // MARK: - Email List View
    
    private var emailListView: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(filteredEmails) { email in
                    EmailRowView(
                        email: email,
                        emailManager: emailManager,
                        isSelected: selectedEmail?.id == email.id,
                        onSelect: { selectedEmail = email }
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }
    
    // MARK: - Footer View
    
    private var footerView: some View {
        HStack(spacing: 12) {
            // Last sync time
            if let lastSync = emailManager.lastSyncTime {
                Text("Updated \(lastSyncFormatted(lastSync))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Refresh button
            Button(action: { emailManager.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(emailManager.isLoading)
            .opacity(emailManager.isLoading ? 0.5 : 1)
            
            // Settings button
            Button(action: { showingSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
    
    private func lastSyncFormatted(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}



// MARK: - Email Row View

struct EmailRowView: View {
    let email: Email
    @ObservedObject var emailManager: EmailManager
    let isSelected: Bool
    let onSelect: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Unread indicator
            Circle()
                .fill(email.isRead ? Color.clear : Color.blue)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            
            // Email content
            VStack(alignment: .leading, spacing: 2) {
                // From and date row
                HStack(alignment: .firstTextBaseline) {
                    Text(email.fromName.isEmpty ? email.from : email.fromName)
                        .font(.system(size: 13, weight: email.isRead ? .regular : .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text(formatDate(email.date))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                // Subject
                Text(email.subject)
                    .font(.system(size: 12))
                    .foregroundColor(email.isRead ? .primary.opacity(0.8) : .primary)
                    .lineLimit(1)
                
                // Preview - always show
                if !email.preview.isEmpty {
                    Text(email.preview)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            
            Spacer(minLength: 0)
            
            // Action buttons (show on hover)
            if isHovered {
                HStack(spacing: 4) {
                    actionButton(
                        icon: email.isRead ? "envelope.badge" : "envelope.open",
                        color: email.isRead ? .orange : .blue
                    ) {
                        toggleReadStatus()
                    }
                    
                    actionButton(icon: "trash", color: .red) {
                        emailManager.deleteEmail(email)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor)
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button(action: { toggleReadStatus() }) {
                Label(email.isRead ? "Mark as Unread" : "Mark as Read",
                      systemImage: email.isRead ? "envelope.badge" : "envelope.open")
            }
            Divider()
            Button(role: .destructive, action: { emailManager.deleteEmail(email) }) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
    
    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.12)
        } else if isHovered {
            return Color.black.opacity(0.04)
        }
        return Color.clear
    }
    
    private func actionButton(icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.black.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
    
    private func toggleReadStatus() {
        guard let currentEmail = emailManager.emails.first(where: { $0.uid == email.uid }) else { return }
        if currentEmail.isRead {
            emailManager.markAsUnread(currentEmail)
        } else {
            emailManager.markAsRead(currentEmail)
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
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

// MARK: - Email Detail View

struct EmailDetailView: View {
    let email: Email
    @ObservedObject var emailManager: EmailManager
    @Binding var selectedEmail: Email?
    @State private var fullBodyHTML: String = ""
    @State private var isLoading: Bool = true
    @State private var showDeleteConfirm: Bool = false
    @State private var markAsReadTimer: Timer?
    @State private var composeWindowController: ComposeWindowController?

    private var currentEmail: Email {
        emailManager.emails.first(where: { $0.id == email.id }) ?? email
    }

    private var canReply: Bool {
        emailManager.account.hasSmtpConfigured
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Back button and actions
            detailHeader
            
            Divider()
                .opacity(0.3)
            
            // Email header info
            emailHeader
            
            Divider()
                .opacity(0.3)
            
            // Email content - fills remaining space
            emailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            loadEmailBody()
            startMarkAsReadTimer()
        }
        .onDisappear {
            markAsReadTimer?.invalidate()
        }
        .alert("Delete Email", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteAndGoBack()
            }
        } message: {
            Text("Are you sure you want to delete this email?")
        }
    }
    
    // MARK: - Detail Header
    
    private var detailHeader: some View {
        HStack(spacing: 12) {
            // Back button
            Button(action: { selectedEmail = nil }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            // Action buttons
            HStack(spacing: 8) {
                if canReply {
                    detailActionButton(icon: "arrowshape.turn.up.left", tooltip: "Reply") {
                        openReply(mode: .reply(currentEmail))
                    }
                    
                    detailActionButton(icon: "arrowshape.turn.up.left.2", tooltip: "Reply All") {
                        openReply(mode: .replyAll(currentEmail))
                    }
                }
                
                detailActionButton(
                    icon: currentEmail.isRead ? "envelope.badge" : "envelope.open",
                    tooltip: currentEmail.isRead ? "Mark Unread" : "Mark Read"
                ) {
                    markAsReadTimer?.invalidate()
                    if currentEmail.isRead {
                        emailManager.markAsUnread(currentEmail)
                    } else {
                        emailManager.markAsRead(currentEmail)
                    }
                }
                
                detailActionButton(icon: "trash", tooltip: "Delete", color: .red) {
                    showDeleteConfirm = true
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
    
    private func detailActionButton(icon: String, tooltip: String, color: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.black.opacity(0.05)))
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
    
    // MARK: - Email Header
    
    private var emailHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Subject
            Text(currentEmail.subject)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
            
            // From
            HStack(spacing: 8) {
                // Avatar placeholder
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Text(String(currentEmail.fromName.prefix(1).uppercased()))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.accentColor)
                    )
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentEmail.fromName.isEmpty ? currentEmail.from : currentEmail.fromName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    
                    if !currentEmail.fromEmail.isEmpty && currentEmail.fromEmail != currentEmail.fromName {
                        Text(currentEmail.fromEmail)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Date
                Text(formatFullDate(currentEmail.date))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            // To
            if !currentEmail.to.isEmpty {
                HStack(spacing: 4) {
                    Text("To:")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(currentEmail.to)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
    
    // MARK: - Email Content
    
    private var emailContent: some View {
        Group {
            if isLoading {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    Spacer()
                }
            } else {
                WebViewRepresentable(html: fullBodyHTML)
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func formatFullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return formatter.string(from: date)
    }
    
    private func loadEmailBody() {
        if !email.body.isEmpty {
            fullBodyHTML = formatEmailBody(email)
            isLoading = false
        } else {
            emailManager.fetchFullBody(for: email) { body in
                fullBodyHTML = formatEmailBody(Email(
                    id: email.id,
                    uid: email.uid,
                    subject: email.subject,
                    from: email.from,
                    fromEmail: email.fromEmail,
                    fromName: email.fromName,
                    to: email.to,
                    date: email.date,
                    preview: email.preview,
                    body: body,
                    contentType: email.contentType,
                    boundary: email.boundary,
                    isRead: email.isRead
                ))
                isLoading = false
            }
        }
    }
    
    private func formatEmailBody(_ email: Email) -> String {
        let parser = MIMEParser(body: email.body, contentType: email.contentType, boundary: email.boundary)
        var html = parser.getHTMLContent()
        
        // Inject clean styling for white background
        let style = """
        <style>
            * { box-sizing: border-box; }
            html, body {
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
                font-size: 13px;
                line-height: 1.6;
                color: #1d1d1f;
                padding: 0;
                margin: 0;
                background: #fff !important;
                -webkit-font-smoothing: antialiased;
            }
            @media (prefers-color-scheme: dark) {
                html, body { background: #1e1e1e !important; color: #e5e5e7 !important; }
                a { color: #6eb5ff !important; }
                pre, code { background: rgba(255,255,255,0.08) !important; }
                blockquote { border-left-color: rgba(255,255,255,0.2) !important; color: #aaa !important; }
            }
            img { max-width: 100%; height: auto; }
            pre, code {
                font-family: 'SF Mono', Menlo, monospace;
                font-size: 12px;
                background: #f5f5f7;
                border-radius: 4px;
                padding: 2px 6px;
            }
            pre { padding: 12px; overflow-x: auto; white-space: pre-wrap; word-wrap: break-word; }
            blockquote {
                margin: 8px 0;
                padding-left: 12px;
                border-left: 3px solid #e5e5e5;
                color: #666;
            }
            a { color: #0071e3; text-decoration: none; }
            a:hover { text-decoration: underline; }
            table { border-collapse: collapse; }
            td, th { padding: 4px 8px; }
            hr { border: none; border-top: 1px solid #e5e5e5; margin: 16px 0; }
        </style>
        """
        
        if html.lowercased().contains("<head>") {
            html = html.replacingOccurrences(of: "<head>", with: "<head>\(style)", options: .caseInsensitive)
        } else if html.lowercased().contains("<html>") {
            html = html.replacingOccurrences(of: "<html>", with: "<html><head>\(style)</head>", options: .caseInsensitive)
        } else {
            html = "\(style)\(html)"
        }
        
        return html
    }
    
    private func startMarkAsReadTimer() {
        guard !currentEmail.isRead else { return }
        markAsReadTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            if !currentEmail.isRead {
                emailManager.markAsRead(currentEmail)
            }
        }
    }
    
    private func deleteAndGoBack() {
        emailManager.deleteEmail(email)
        selectedEmail = nil
    }
    
    private func openReply(mode: ComposeMode) {
        var emailWithBody = currentEmail
        if !fullBodyHTML.isEmpty {
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
                body: email.body.isEmpty ? fullBodyHTML : email.body,
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
            debugLog("[Compose] Email sent successfully")
        }
        composeWindowController = controller
    }
}

// MARK: - WebView

struct WebViewRepresentable: NSViewRepresentable {
    let html: String
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }
    
    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}

// MARK: - Preview

#Preview {
    ContentView(emailManager: EmailManager(
        account: IMAPAccount(
            name: "Test",
            host: "imap.test.com",
            port: 993,
            username: "test@test.com",
            useSSL: true
        ),
        folderConfig: FolderConfig(name: "Inbox", folderPath: "INBOX")
    ))
    .frame(width: 400, height: 500)
}
