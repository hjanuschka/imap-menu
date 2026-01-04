import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var config = AppConfig.load()
    @State private var selectedAccountID: UUID?
    @State private var selectedVirtualFolderID: UUID?
    @State private var testingConnection = false
    @State private var testMessage = ""
    @State private var showFolderBrowser = false
    @State private var availableFolders: [String] = []
    @State private var hasUnsavedChanges = false
    @State private var selectedTab = 0  // 0 = accounts, 1 = virtual folders

    var body: some View {
        VStack(spacing: 0) {
            // Tab selector
            Picker("", selection: $selectedTab) {
                Text("Accounts").tag(0)
                Text("Virtual Folders").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()
            
            Divider()
            
            if selectedTab == 0 {
                accountsView
            } else {
                virtualFoldersView
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
    
    // MARK: - Accounts View
    
    private var accountsView: some View {
        HSplitView {
            // Left: Account list
            VStack(alignment: .leading, spacing: 8) {
                Text("Accounts")
                    .font(.headline)
                    .padding(.horizontal)

                List(selection: $selectedAccountID) {
                    ForEach($config.accounts) { $account in
                        AccountRow(account: $account)
                            .tag(account.id)
                    }
                }

                HStack {
                    Button("+") {
                        let newAccount = IMAPAccount(name: "New Account", host: "", username: "")
                        config.accounts.append(newAccount)
                        selectedAccountID = newAccount.id
                    }

                    if let selectedID = selectedAccountID,
                       config.accounts.contains(where: { $0.id == selectedID }) {
                        Button("-") {
                            config.accounts.removeAll { $0.id == selectedID }
                            selectedAccountID = config.accounts.first?.id
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal)
            }
            .frame(minWidth: 200, maxWidth: 250)

            // Right: Account details
            if let selectedID = selectedAccountID,
               let accountIndex = config.accounts.firstIndex(where: { $0.id == selectedID }) {
                AccountDetailView(
                    account: $config.accounts[accountIndex],
                    testingConnection: $testingConnection,
                    testMessage: $testMessage,
                    showFolderBrowser: $showFolderBrowser,
                    availableFolders: $availableFolders
                )
            } else {
                Text("Select an account or create a new one")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 950, minHeight: 750)
        .padding()
        .toolbar {
            ToolbarItem(placement: .status) {
                Text("IMAPMenu v\(appVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save & Close") {
                    saveConfig()
                    dismiss()
                }
            }
        }
        .sheet(isPresented: $showFolderBrowser) {
            if let accountIndex = config.accounts.firstIndex(where: { $0.id == selectedAccountID }) {
                FolderBrowserView(
                    account: config.accounts[accountIndex],
                    availableFolders: $availableFolders,
                    isPresented: $showFolderBrowser,
                    onSelectFolder: { folder in
                        config.accounts[accountIndex].folders.append(
                            FolderConfig(name: folder, folderPath: folder)
                        )
                    }
                )
            }
        }
        .onAppear {
            if selectedAccountID == nil {
                selectedAccountID = config.accounts.first?.id
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    
    // MARK: - Virtual Folders View
    
    private var virtualFoldersView: some View {
        HSplitView {
            // Left: Virtual folder list
            VStack(alignment: .leading, spacing: 8) {
                Text("Virtual Folders")
                    .font(.headline)
                    .padding(.horizontal)
                
                Text("Aggregate emails from multiple accounts")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                List(selection: $selectedVirtualFolderID) {
                    ForEach($config.virtualFolders) { $vf in
                        HStack {
                            Image(systemName: vf.icon)
                                .foregroundColor(Color(NSColor(hex: vf.iconColor) ?? .systemBlue))
                            Text(vf.name)
                        }
                        .tag(vf.id)
                    }
                }

                HStack {
                    Button("+") {
                        let newVF = VirtualFolder(name: "New Virtual Folder")
                        config.virtualFolders.append(newVF)
                        selectedVirtualFolderID = newVF.id
                    }

                    if let selectedID = selectedVirtualFolderID,
                       config.virtualFolders.contains(where: { $0.id == selectedID }) {
                        Button("-") {
                            config.virtualFolders.removeAll { $0.id == selectedID }
                            selectedVirtualFolderID = config.virtualFolders.first?.id
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal)
            }
            .frame(minWidth: 200, maxWidth: 250)

            // Right: Virtual folder details
            if let index = config.virtualFolders.firstIndex(where: { $0.id == selectedVirtualFolderID }) {
                VirtualFolderDetailView(
                    virtualFolder: $config.virtualFolders[index],
                    accounts: config.accounts
                )
            } else {
                Text("Select a virtual folder or create a new one")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func saveConfig() {
        config.save()
        NotificationCenter.default.post(name: NSNotification.Name("RefreshEmails"), object: nil)
        testMessage = "Configuration saved and reloaded"
    }
}

// MARK: - Virtual Folder Detail View

struct VirtualFolderDetailView: View {
    @Binding var virtualFolder: VirtualFolder
    let accounts: [IMAPAccount]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Basic settings
                GroupBox(label: Text("Virtual Folder Settings")) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Name", text: $virtualFolder.name)
                        
                        HStack {
                            Toggle("Enabled", isOn: $virtualFolder.enabled)
                            Spacer()
                        }
                        
                        HStack {
                            Text("Icon:")
                            TextField("SF Symbol", text: $virtualFolder.icon)
                                .frame(width: 150)
                            Image(systemName: virtualFolder.icon)
                                .foregroundColor(Color(virtualFolder.nsColor))
                        }
                        
                        ColorPicker("Icon Color:", selection: Binding(
                            get: { Color(virtualFolder.nsColor) },
                            set: { virtualFolder.iconColor = $0.hexString }
                        ))
                        
                        Picker("Max Emails:", selection: $virtualFolder.maxEmails) {
                            Text("50").tag(50)
                            Text("100").tag(100)
                            Text("200").tag(200)
                            Text("500").tag(500)
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding()
                }
                
                // Sources
                GroupBox(label: Text("Email Sources")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Select which folders to aggregate emails from:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        ForEach(accounts) { account in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(account.name)
                                    .font(.headline)
                                
                                ForEach(account.folders.filter { $0.enabled }) { folder in
                                    HStack {
                                        let isSelected = virtualFolder.sources.contains { 
                                            $0.accountId == account.id && $0.folderPath == folder.folderPath 
                                        }
                                        
                                        Toggle(isOn: Binding(
                                            get: { isSelected },
                                            set: { newValue in
                                                if newValue {
                                                    virtualFolder.sources.append(
                                                        FolderSource(accountId: account.id, folderPath: folder.folderPath)
                                                    )
                                                } else {
                                                    virtualFolder.sources.removeAll { 
                                                        $0.accountId == account.id && $0.folderPath == folder.folderPath 
                                                    }
                                                }
                                            }
                                        )) {
                                            HStack {
                                                Image(systemName: folder.icon)
                                                    .foregroundColor(Color(folder.nsColor))
                                                Text(folder.name)
                                            }
                                        }
                                    }
                                    .padding(.leading, 16)
                                }
                            }
                            .padding(.bottom, 8)
                        }
                        
                        if accounts.isEmpty {
                            Text("No accounts configured. Add accounts first.")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                }
                
                // Filters
                GroupBox(label: Text("Filters (Optional)")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Only show emails that match these filters:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Picker("Filter Logic:", selection: $virtualFolder.groupLogic) {
                            Text("Match ANY filter").tag(FolderConfig.FilterLogic.or)
                            Text("Match ALL filters").tag(FolderConfig.FilterLogic.and)
                        }
                        .pickerStyle(.segmented)
                        
                        ForEach($virtualFolder.filterGroups) { $group in
                            HStack {
                                Toggle("", isOn: $group.enabled)
                                    .labelsHidden()
                                TextField("Group name", text: $group.name)
                                    .frame(width: 150)
                                
                                Spacer()
                                
                                Button(action: {
                                    virtualFolder.filterGroups.removeAll { $0.id == group.id }
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                            
                            // Simple filter list (read-only)
                            ForEach(group.filters, id: \.id) { filter in
                                HStack {
                                    Text("\(filter.field.rawValue) \(filter.matchType.rawValue) '\(filter.pattern)'")
                                        .font(.caption)
                                }
                                .padding(.leading, 24)
                            }
                            
                            Button(action: {
                                var updatedGroup = group
                                updatedGroup.filters.append(EmailFilter(
                                    id: UUID(),
                                    filterType: .include,
                                    field: .subject,
                                    matchType: .contains,
                                    pattern: "JXL"  // Default example pattern
                                ))
                                if let idx = virtualFolder.filterGroups.firstIndex(where: { $0.id == group.id }) {
                                    virtualFolder.filterGroups[idx] = updatedGroup
                                }
                            }) {
                                Label("Add Filter", systemImage: "plus")
                            }
                            .padding(.leading, 24)
                        }
                        
                        Button(action: {
                            virtualFolder.filterGroups.append(FilterGroup(
                                name: "Filter Group",
                                filters: [],
                                logic: .and,
                                enabled: true
                            ))
                        }) {
                            Label("Add Filter Group", systemImage: "plus.circle")
                        }
                    }
                    .padding()
                }
            }
            .padding()
        }
    }
}

// Helper extension
extension Color {
    var hexString: String {
        guard let components = NSColor(self).cgColor.components, components.count >= 3 else {
            return "#007AFF"
        }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

struct AccountRow: View {
    @Binding var account: IMAPAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(account.name)
                .font(.body)
            Text(account.host.isEmpty ? "Not configured" : account.host)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct AccountDetailView: View {
    @Binding var account: IMAPAccount
    @Binding var testingConnection: Bool
    @Binding var testMessage: String
    @Binding var showFolderBrowser: Bool
    @Binding var availableFolders: [String]
    @State private var testingSmtp = false
    @State private var smtpTestMessage = ""
    @State private var isAuthenticatingOAuth2 = false
    @State private var oauth2Message = ""
    @StateObject private var oauth2Manager = OAuth2Manager.shared
    
    private var hasOAuth2Tokens: Bool {
        OAuth2Manager.shared.loadTokens(for: account.id.uuidString) != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Account Type
                GroupBox(label: Text("Account Type")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Type", selection: $account.accountType) {
                            ForEach(IMAPAccount.AccountType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: account.accountType) { newType in
                            // Auto-fill server settings for Gmail ONLY if host is empty or default
                            if newType == .gmailAppPassword || newType == .gmailOAuth2 {
                                // Only auto-fill if not already configured
                                if account.host.isEmpty || account.host == "imap.example.com" {
                                    account.host = "imap.gmail.com"
                                    account.port = 993
                                    account.useSSL = true
                                }
                                if account.smtpHost.isEmpty {
                                    account.smtpHost = "smtp.gmail.com"
                                    account.smtpPort = 587
                                    account.smtpUseSSL = true
                                }
                            }
                        }
                        
                        if account.accountType == .gmailAppPassword {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("✓ Recommended for Gmail!")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.green)
                                Text("1. Enable 2-Step Verification in your Google Account")
                                Text("2. Go to myaccount.google.com/apppasswords")
                                Text("3. Generate an App Password for 'Mail'")
                                Text("4. Use that 16-character password below")
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                            
                            Link("Generate App Password →", destination: URL(string: "https://myaccount.google.com/apppasswords")!)
                                .font(.caption)
                        }
                        
                        if account.accountType == .gmailOAuth2 {
                            Text("Advanced: Requires creating OAuth2 credentials in Google Cloud Console.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                }
                
                // Account settings
                GroupBox(label: Text("IMAP Settings (Receiving)")) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Account Name", text: $account.name)

                        TextField("IMAP Host", text: $account.host)
                            .disabled(account.accountType == .gmailAppPassword || account.accountType == .gmailOAuth2)

                        HStack {
                            TextField("Port", value: $account.port, format: .number)
                                .frame(width: 80)
                                .disabled(account.accountType == .gmailAppPassword || account.accountType == .gmailOAuth2)
                            Toggle("Use SSL", isOn: $account.useSSL)
                                .disabled(account.accountType == .gmailAppPassword || account.accountType == .gmailOAuth2)
                        }

                        TextField("Username / Email", text: $account.username)
                            .textContentType(.username)

                        if account.accountType == .imap || account.accountType == .gmailAppPassword {
                            SecureField(account.accountType == .gmailAppPassword ? "App Password" : "Password", text: $account.password)
                                .textContentType(.password)
                        }

                        HStack {
                            Button("Test Connection") {
                                testConnection()
                            }
                            .disabled(testingConnection || account.host.isEmpty || (account.accountType == .gmailOAuth2 && !hasOAuth2Tokens) || (account.accountType == .gmailAppPassword && account.password.isEmpty))

                            if testingConnection {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }

                            if !testMessage.isEmpty {
                                Text(testMessage)
                                    .font(.caption)
                                    .foregroundColor(testMessage.contains("Success") || testMessage.contains("✓") ? .green : .red)
                            }
                        }
                    }
                    .padding()
                }
                
                // OAuth2 Settings (Gmail only)
                if account.accountType == .gmailOAuth2 {
                    GroupBox(label: Text("OAuth2 Authentication")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("To use Gmail, you need to create OAuth2 credentials:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("1. Go to Google Cloud Console")
                                Text("2. Create a new project or select existing")
                                Text("3. Enable Gmail API")
                                Text("4. Create OAuth2 credentials (Desktop app)")
                                Text("5. Add your email to test users")
                                Text("6. Copy Client ID and Secret below")
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                            
                            Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                                .font(.caption)
                            
                            Divider()
                            
                            TextField("OAuth2 Client ID", text: $account.oauth2ClientId)
                            SecureField("OAuth2 Client Secret", text: $account.oauth2ClientSecret)
                            
                            HStack {
                                if hasOAuth2Tokens {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Authenticated")
                                        .foregroundColor(.green)
                                    
                                    Button("Re-authenticate") {
                                        authenticateOAuth2()
                                    }
                                    .disabled(isAuthenticatingOAuth2 || account.oauth2ClientId.isEmpty)
                                } else {
                                    Button("Authenticate with Google") {
                                        authenticateOAuth2()
                                    }
                                    .disabled(isAuthenticatingOAuth2 || account.oauth2ClientId.isEmpty || account.oauth2ClientSecret.isEmpty)
                                }
                                
                                if isAuthenticatingOAuth2 {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                }
                            }
                            
                            if !oauth2Message.isEmpty {
                                Text(oauth2Message)
                                    .font(.caption)
                                    .foregroundColor(oauth2Message.contains("✓") ? .green : .red)
                            }
                        }
                        .padding()
                    }
                }

                // SMTP settings
                GroupBox(label: Text("SMTP Settings (Sending)")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            TextField("SMTP Host", text: $account.smtpHost)
                            Text("(e.g., smtp.gmail.com)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            TextField("Port", value: $account.smtpPort, format: .number)
                                .frame(width: 80)
                            Toggle("Use SSL/TLS", isOn: $account.smtpUseSSL)

                            Text("(587 for STARTTLS, 465 for SSL)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            TextField("SMTP Username (if different)", text: $account.smtpUsername)
                            if account.smtpUsername.isEmpty {
                                Text("Uses IMAP username")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        HStack {
                            SecureField("SMTP Password (if different)", text: $account.smtpPassword)
                                .textContentType(.password)
                            if account.smtpPassword.isEmpty {
                                Text("Uses IMAP password")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Divider()
                        
                        Text("From Address (for outgoing emails)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HStack {
                            TextField("From Email", text: $account.fromEmail)
                            if account.fromEmail.isEmpty {
                                Text("Uses '\(account.username)'")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        HStack {
                            TextField("From Name", text: $account.fromName)
                            if account.fromName.isEmpty {
                                Text("Uses '\(account.name)'")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Email Signature:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextEditor(text: $account.signature)
                                .font(.body)
                                .frame(height: 60)
                                .border(Color.secondary.opacity(0.2))
                        }

                        HStack {
                            Button("Test SMTP") {
                                testSmtpConnection()
                            }
                            .disabled(testingSmtp || account.smtpHost.isEmpty)

                            if testingSmtp {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }

                            if !smtpTestMessage.isEmpty {
                                Text(smtpTestMessage)
                                    .font(.caption)
                                    .foregroundColor(smtpTestMessage.contains("✓") ? .green : .red)
                            }

                            Spacer()

                            if account.smtpHost.isEmpty {
                                Text("Configure SMTP to enable Reply feature")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    .padding()
                }

                // Folders
                GroupBox(label: Text("Folders to Monitor")) {
                    VStack(alignment: .leading, spacing: 8) {
                        if account.folders.isEmpty {
                            Text("No folders configured. Each folder gets its own menubar icon.")
                                .foregroundColor(.secondary)
                                .padding()
                        } else {
                            ForEach($account.folders) { $folder in
                                FolderDetailRow(
                                    folder: $folder,
                                    accountEmail: account.emailAddress,
                                    onDelete: {
                                        account.folders.removeAll { $0.id == folder.id }
                                    }
                                )
                            }
                        }

                        HStack {
                            Button("Browse Folders...") {
                                browseFolders()
                            }
                            .disabled(account.host.isEmpty)

                            Button("Add Custom...") {
                                account.folders.append(
                                    FolderConfig(name: "New Folder", folderPath: "INBOX")
                                )
                            }
                        }
                        .padding(.top, 8)
                    }
                    .padding()
                }

                Spacer()
            }
            .padding()
        }
    }

    private func testConnection() {
        testingConnection = true
        testMessage = ""

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let config: IMAPConfig
                if account.accountType == .gmailOAuth2 {
                    guard let tokens = OAuth2Manager.shared.loadTokens(for: account.id.uuidString) else {
                        throw OAuth2Manager.OAuth2Error.missingCredentials
                    }
                    config = IMAPConfig(
                        host: account.host,
                        port: account.port,
                        username: account.username,
                        accessToken: tokens.accessToken,
                        useSSL: account.useSSL
                    )
                } else {
                    config = IMAPConfig(
                        host: account.host,
                        port: account.port,
                        username: account.username,
                        password: account.password,
                        useSSL: account.useSSL
                    )
                }
                let connection = IMAPConnection(config: config)
                try connection.connect()
                connection.disconnect()

                DispatchQueue.main.async {
                    testingConnection = false
                    testMessage = "✓ Connection successful"
                }
            } catch {
                DispatchQueue.main.async {
                    testingConnection = false
                    testMessage = "✗ \(error.localizedDescription)"
                }
            }
        }
    }

    private func authenticateOAuth2() {
        isAuthenticatingOAuth2 = true
        oauth2Message = ""
        
        let config = OAuth2Config(
            clientId: account.oauth2ClientId,
            clientSecret: account.oauth2ClientSecret,
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            redirectURI: "com.imapmenu://oauth2callback",
            scopes: ["https://mail.google.com/"]
        )
        
        OAuth2Manager.shared.authorize(config: config, email: account.username) { result in
            DispatchQueue.main.async {
                isAuthenticatingOAuth2 = false
                
                switch result {
                case .success(let tokens):
                    OAuth2Manager.shared.saveTokens(tokens, for: account.id.uuidString)
                    oauth2Message = "✓ Authentication successful!"
                case .failure(let error):
                    oauth2Message = "✗ \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func browseFolders() {
        testMessage = "Loading folders..."

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let config: IMAPConfig
                if account.accountType == .gmailOAuth2 {
                    guard let tokens = OAuth2Manager.shared.loadTokens(for: account.id.uuidString) else {
                        throw OAuth2Manager.OAuth2Error.missingCredentials
                    }
                    config = IMAPConfig(
                        host: account.host,
                        port: account.port,
                        username: account.username,
                        accessToken: tokens.accessToken,
                        useSSL: account.useSSL
                    )
                } else {
                    config = IMAPConfig(
                        host: account.host,
                        port: account.port,
                        username: account.username,
                        password: account.password,
                        useSSL: account.useSSL
                    )
                }
                let connection = IMAPConnection(config: config)
                try connection.connect()
                let folders = try connection.listFolders()
                connection.disconnect()

                DispatchQueue.main.async {
                    availableFolders = folders
                    testMessage = ""
                    showFolderBrowser = true
                }
            } catch {
                DispatchQueue.main.async {
                    testMessage = "✗ Failed to load folders: \(error.localizedDescription)"
                }
            }
        }
    }

    private func testSmtpConnection() {
        testingSmtp = true
        smtpTestMessage = ""

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
                connection.disconnect()

                DispatchQueue.main.async {
                    testingSmtp = false
                    smtpTestMessage = "✓ SMTP connection successful"
                }
            } catch {
                DispatchQueue.main.async {
                    testingSmtp = false
                    smtpTestMessage = "✗ \(error.localizedDescription)"
                }
            }
        }
    }
}

struct FolderDetailRow: View {
    @Binding var folder: FolderConfig
    let accountEmail: String
    let onDelete: () -> Void
    @State private var showFilters = false

    var body: some View {
        VStack(spacing: 8) {
            FolderRowView(folder: $folder, onDelete: onDelete)

            if folder.enabled {
                // Quick options
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .foregroundColor(.secondary)
                            .frame(width: 20)
                        
                        // Exclude own emails toggle
                        Toggle("Exclude emails from me (\(accountEmail))", isOn: $folder.excludeOwnEmails)
                            .font(.caption)
                        
                        Spacer()
                        
                        // Popover width
                        Picker("Width:", selection: $folder.popoverWidth) {
                            Text("S").tag(FolderConfig.PopoverWidth.small)
                            Text("M").tag(FolderConfig.PopoverWidth.medium)
                            Text("L").tag(FolderConfig.PopoverWidth.large)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 100)
                    }
                    
                    // Fetch settings
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle")
                            .foregroundColor(.secondary)
                            .frame(width: 20)
                        
                        Text("Fetch:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HStack(spacing: 4) {
                            TextField("", value: $folder.maxEmails, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Text("emails")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Text("(0 = all)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        HStack(spacing: 4) {
                            Text("from last")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("", value: $folder.daysToFetch, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                            Text("days")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Text("(0 = all time)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    // Filter Groups section
                    DisclosureGroup(
                        isExpanded: $showFilters,
                        content: {
                            FilterGroupsView(folder: $folder)
                        },
                        label: {
                            HStack {
                                Text("Filter Groups")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                if !folder.filterGroups.isEmpty {
                                    Text("(\(folder.filterGroups.count) groups)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    )
                    .padding(.leading, 32)
                }
                .padding(.leading, 40)
                .padding(.bottom, 4)
            }

            Divider()
        }
    }
}

// MARK: - Filter Groups View

struct FilterGroupsView: View {
    @Binding var folder: FolderConfig
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Group logic selector (only if multiple groups)
            if folder.filterGroups.count > 1 {
                HStack {
                    Text("Combine groups with:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: $folder.groupLogic) {
                        Text("AND (all must match)").tag(FolderConfig.FilterLogic.and)
                        Text("OR (any must match)").tag(FolderConfig.FilterLogic.or)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }
                .padding(.bottom, 8)
            }
            
            // Groups list
            ForEach($folder.filterGroups) { $group in
                FilterGroupRow(group: $group, onDelete: {
                    folder.filterGroups.removeAll { $0.id == group.id }
                })
            }
            
            // Add group button
            Button(action: {
                folder.filterGroups.append(FilterGroup())
            }) {
                Label("Add Filter Group", systemImage: "plus.rectangle.on.rectangle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)
            
            // Help text
            VStack(alignment: .leading, spacing: 4) {
                Text("💡 How Filter Groups Work:")
                    .font(.caption2)
                    .fontWeight(.medium)
                Text("• Each group can contain multiple rules combined with AND/OR")
                Text("• Groups themselves are combined using the selector above")
                Text("• Exclude rules always reject emails (within their group)")
                Text("• Example: Group1 (Subject=jxl OR From=foolip) AND Group2 (Exclude Name=Helmut)")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
            .padding(.top, 8)
        }
        .padding(.vertical, 8)
    }
}

struct FilterGroupRow: View {
    @Binding var group: FilterGroup
    let onDelete: () -> Void
    @State private var isExpanded = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Group header
            HStack {
                Toggle("", isOn: $group.enabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                
                TextField("Group name", text: $group.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .font(.caption)
                
                Picker("", selection: $group.logic) {
                    Text("OR").tag(FilterGroup.GroupLogic.or)
                    Text("AND").tag(FilterGroup.GroupLogic.and)
                }
                .pickerStyle(.segmented)
                .frame(width: 80)
                .help("How rules within this group are combined")
                
                // Server-side search toggle
                Toggle("⚡Server", isOn: $group.useServerSearch)
                    .toggleStyle(.button)
                    .font(.caption2)
                    .help("Use IMAP server-side SEARCH (much faster!)")
                
                Text("(\(group.filters.count) rules)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .background(group.useServerSearch ? Color.blue.opacity(0.1) : Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            .opacity(group.enabled ? 1.0 : 0.6)
            
            // Group filters (expandable)
            if isExpanded && group.enabled {
                VStack(alignment: .leading, spacing: 4) {
                    // Server search custom query option
                    if group.useServerSearch {
                        HStack {
                            Text("Custom IMAP SEARCH:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            TextField("e.g., OR SUBJECT jxl FROM foolip", text: $group.serverSearchQuery)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                            
                            if group.serverSearchQuery.isEmpty {
                                Text("(auto-built from rules)")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(.bottom, 4)
                        
                        // Show what query will be used
                        if let query = group.buildIMAPSearchQuery() {
                            HStack {
                                Text("Query:")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(query)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.blue)
                            }
                            .padding(.bottom, 4)
                        }
                    }
                    
                    ForEach($group.filters) { $filter in
                        FilterRuleRow(filter: $filter, onDelete: {
                            group.filters.removeAll { $0.id == filter.id }
                        })
                    }
                    
                    HStack(spacing: 12) {
                        Button(action: {
                            group.filters.append(EmailFilter(filterType: .include))
                        }) {
                            Label("Include", systemImage: "plus.circle")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.green)
                        
                        Button(action: {
                            group.filters.append(EmailFilter(filterType: .exclude))
                        }) {
                            Label("Exclude", systemImage: "minus.circle")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.orange)
                    }
                    .padding(.leading, 24)
                    
                    if group.useServerSearch {
                        Text("💡 Server search: Only Include rules are sent to server. Exclude rules still filter client-side.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                }
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, 4)
    }
}

struct FilterRuleRow: View {
    @Binding var filter: EmailFilter
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 6) {
            // Enable/disable
            Toggle("", isOn: $filter.enabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
            
            // Filter type indicator
            Image(systemName: filter.filterType == .include ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption)
                .foregroundColor(filter.filterType == .include ? .green : .orange)
            
            // Filter type
            Picker("", selection: $filter.filterType) {
                Text("Include").tag(EmailFilter.FilterType.include)
                Text("Exclude").tag(EmailFilter.FilterType.exclude)
            }
            .frame(width: 75)
            .labelsHidden()
            
            // Field
            Picker("", selection: $filter.field) {
                ForEach(EmailFilter.MatchField.allCases, id: \.self) { field in
                    Text(field.rawValue).tag(field)
                }
            }
            .frame(width: 95)
            .labelsHidden()
            
            // Match type
            Picker("", selection: $filter.matchType) {
                ForEach(EmailFilter.MatchType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .frame(width: 95)
            .labelsHidden()
            
            // Pattern
            TextField("Pattern...", text: $filter.pattern)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            
            // Case sensitive toggle
            Toggle("Aa", isOn: $filter.caseSensitive)
                .toggleStyle(.button)
                .font(.caption2)
                .help("Case Sensitive")
            
            // Delete button
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .opacity(filter.enabled ? 1.0 : 0.5)
    }
}

struct FolderRowView: View {
    @Binding var folder: FolderConfig
    let onDelete: () -> Void
    @State private var showingIconPicker = false
    @State private var showingColorPicker = false

    private var iconColor: Color {
        if folder.iconColor.isEmpty {
            return .accentColor
        }
        return Color(nsColor: NSColor(hex: folder.iconColor) ?? .labelColor)
    }

    private var colorPreview: Color {
        if folder.iconColor.isEmpty {
            return .gray
        }
        return Color(nsColor: NSColor(hex: folder.iconColor) ?? .gray)
    }
    
    @ViewBuilder
    private var iconPreview: some View {
        switch folder.iconType {
        case .sfSymbol:
            Image(systemName: folder.icon)
                .foregroundColor(iconColor)
        case .url:
            AsyncImage(url: URL(string: folder.icon)) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Image(systemName: "photo")
                    .foregroundColor(.secondary)
            }
        case .file:
            if let nsImage = NSImage(contentsOfFile: NSString(string: folder.icon).expandingTildeInPath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "doc")
                    .foregroundColor(.secondary)
            }
        }
    }

    var body: some View {
        HStack {
            Toggle(isOn: $folder.enabled) {
                HStack(spacing: 8) {
                    // Icon picker button
                    Button(action: { showingIconPicker = true }) {
                        iconPreview
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingIconPicker) {
                        IconPickerView(selectedIcon: $folder.icon, iconType: $folder.iconType)
                    }

                    // Color picker button
                    Button(action: { showingColorPicker = true }) {
                        Circle()
                            .fill(colorPreview)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingColorPicker) {
                        ColorPickerView(selectedColor: $folder.iconColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Display Name", text: $folder.name)
                            .textFieldStyle(.plain)
                            .font(.body)
                        TextField("Folder Path", text: $folder.folderPath)
                            .textFieldStyle(.plain)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

struct ColorPickerView: View {
    @Binding var selectedColor: String
    @Environment(\.dismiss) var dismiss

    let presetColors = [
        ("Default", ""),
        ("Red", "#FF3B30"),
        ("Orange", "#FF9500"),
        ("Yellow", "#FFCC00"),
        ("Green", "#34C759"),
        ("Teal", "#5AC8FA"),
        ("Blue", "#007AFF"),
        ("Indigo", "#5856D6"),
        ("Purple", "#AF52DE"),
        ("Pink", "#FF2D55"),
        ("Gray", "#8E8E93"),
        ("Black", "#000000")
    ]

    var body: some View {
        VStack(spacing: 16) {
            Text("Choose Color")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 12) {
                ForEach(presetColors, id: \.0) { (name, hex) in
                    Button(action: {
                        selectedColor = hex
                        dismiss()
                    }) {
                        VStack(spacing: 4) {
                            Circle()
                                .fill(hex.isEmpty ? Color.gray : Color(nsColor: NSColor(hex: hex) ?? .gray))
                                .frame(width: 40, height: 40)
                                .overlay(Circle().stroke(selectedColor == hex ? Color.accentColor : Color.clear, lineWidth: 3))
                            Text(name)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            HStack {
                Text("Custom:")
                    .foregroundColor(.secondary)
                TextField("#FF0000", text: $selectedColor)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)

                if !selectedColor.isEmpty {
                    Circle()
                        .fill(Color(nsColor: NSColor(hex: selectedColor) ?? .gray))
                        .frame(width: 24, height: 24)
                }

                Button("Done") {
                    dismiss()
                }
            }
        }
        .padding()
        .frame(width: 350, height: 350)
    }
}

struct IconPickerView: View {
    @Binding var selectedIcon: String
    @Binding var iconType: FolderConfig.IconType
    @Environment(\.dismiss) var dismiss
    @State private var searchText = ""
    @State private var customURL = ""
    @State private var customFilePath = ""
    @State private var selectedTab = 0

    let allIconsList: [String] = {
        var icons: [String] = []

        let baseSymbols = [
            "envelope", "tray", "paperplane", "mail", "doc", "folder",
            "archivebox", "star", "flag", "bell", "tag", "bookmark",
            "gear", "person", "briefcase", "cart", "creditcard", "bag",
            "phone", "message", "bubble", "video", "mic", "speaker",
            "terminal", "hammer", "wrench", "cpu", "lock", "key",
            "photo", "camera", "film", "play", "pause", "music.note",
            "book", "newspaper", "graduationcap", "building", "house",
            "heart", "bolt", "flame", "sparkle", "leaf", "globe",
            "sun.max", "moon", "cloud", "snowflake", "drop", "wind",
            "clock", "timer", "stopwatch", "calendar", "alarm",
            "location", "map", "pin", "mappin", "arrow.up", "arrow.down",
            "arrow.left", "arrow.right", "chevron.up", "chevron.down",
            "plus", "minus", "xmark", "checkmark", "circle", "square",
            "rectangle", "triangle", "diamond", "hexagon", "shield",
            "trash", "pencil", "eraser", "scissors", "magnifyingglass",
            "slider.horizontal.3", "paintbrush", "eyedropper", "rotate.left",
            "rotate.right", "chart.bar", "chart.pie", "chart.line.uptrend.xyaxis",
            "gauge", "speedometer", "battery.100", "antenna.radiowaves.left.and.right",
            "wifi", "network", "server.rack", "printer", "scanner",
            "keyboard", "mouse", "display", "desktopcomputer", "laptopcomputer",
            "ipad", "iphone", "applewatch", "airpods", "headphones",
            "airplayvideo", "tv", "hifispeaker", "homepod", "cable.connector",
            "flashlight.on.fill", "flashlight.off.fill", "lightbulb", "lamp.desk",
            "fan", "air.conditioner.horizontal", "heater.vertical", "thermometer",
            "humidity", "tropicalstorm", "tornado", "rainbow", "sunset",
            "hare", "tortoise", "ant", "ladybug", "bird", "fish",
            "pawprint", "dog", "cat", "sportscourt", "basketball", "football",
            "baseball", "tennis.racket", "hockey.puck", "figure.walk", "figure.run",
            "bicycle", "car", "bus", "tram", "train.side.front.car",
            "airplane", "ferry", "fuelpump", "parkingsign", "steeringwheel",
            "wrench.and.screwdriver", "bandage", "cross.case", "pills",
            "syringe", "medical.thermometer", "stethoscope", "bed.double",
            "fork.knife", "cup.and.saucer", "wineglass", "birthday.cake",
            "gift", "balloon", "party.popper", "popcorn", "carrot",
            "leaf.arrow.triangle.circlepath", "bin.xmark", "recycle"
        ]

        icons.append(contentsOf: baseSymbols)

        let fillableSymbols = [
            "envelope", "tray", "paperplane", "doc", "folder",
            "archivebox", "star", "flag", "bell", "tag", "bookmark",
            "gear", "person", "briefcase", "cart", "creditcard", "bag",
            "phone", "message", "bubble", "video", "heart", "bolt",
            "flame", "leaf", "sun.max", "moon", "cloud", "circle",
            "square", "triangle", "shield", "trash", "pencil", "checkmark",
            "photo", "camera", "play", "pause", "house", "building",
            "location", "mappin", "clock", "calendar", "lock", "key"
        ]

        for symbol in fillableSymbols {
            icons.append("\(symbol).fill")
        }

        let circleSymbols = [
            "envelope", "star", "flag", "bell", "gear", "person",
            "plus", "minus", "xmark", "checkmark", "arrow.up", "arrow.down",
            "play", "pause", "location", "questionmark", "exclamationmark"
        ]

        for symbol in circleSymbols {
            icons.append("\(symbol).circle")
            icons.append("\(symbol).circle.fill")
        }

        let badgeSymbols = [
            "envelope", "folder", "tray", "person", "star", "flag"
        ]

        for symbol in badgeSymbols {
            icons.append("\(symbol).badge.plus")
        }

        return Array(Set(icons)).sorted()
    }()

    var filteredIcons: [String] {
        if searchText.isEmpty {
            return allIconsList
        }
        return allIconsList.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Choose Icon")
                .font(.headline)
            
            // Tab selector
            Picker("Icon Type", selection: $selectedTab) {
                Text("SF Symbols").tag(0)
                Text("Image URL").tag(1)
                Text("Local File").tag(2)
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedTab) { newTab in
                switch newTab {
                case 0: iconType = .sfSymbol
                case 1: iconType = .url
                case 2: iconType = .file
                default: break
                }
            }
            .onAppear {
                selectedTab = iconType == .sfSymbol ? 0 : (iconType == .url ? 1 : 2)
                customURL = iconType == .url ? selectedIcon : ""
                customFilePath = iconType == .file ? selectedIcon : ""
            }
            
            // Tab content
            switch selectedTab {
            case 0:
                sfSymbolPicker
            case 1:
                urlPicker
            case 2:
                filePicker
            default:
                EmptyView()
            }
        }
        .padding()
        .frame(width: 550, height: 550)
    }
    
    // SF Symbol picker
    private var sfSymbolPicker: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search SF Symbols...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                
                Text("\(filteredIcons.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 55))], spacing: 8) {
                    ForEach(filteredIcons, id: \.self) { icon in
                        Button(action: {
                            selectedIcon = icon
                            iconType = .sfSymbol
                            dismiss()
                        }) {
                            VStack(spacing: 2) {
                                Image(systemName: icon)
                                    .font(.title3)
                                    .frame(width: 44, height: 44)
                                    .background(selectedIcon == icon && iconType == .sfSymbol ? Color.accentColor.opacity(0.2) : Color.clear)
                                    .cornerRadius(8)
                                Text(icon.replacingOccurrences(of: ".", with: "\n"))
                                    .font(.system(size: 7))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(.secondary)
                                    .frame(height: 16)
                            }
                            .frame(width: 55)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }

            HStack {
                Text("Custom:")
                    .foregroundColor(.secondary)
                TextField("SF Symbol name", text: $selectedIcon)
                    .textFieldStyle(.roundedBorder)
                Button("Apply") {
                    iconType = .sfSymbol
                    dismiss()
                }
            }
        }
    }
    
    // URL picker
    private var urlPicker: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter an image URL:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextField("https://example.com/icon.png", text: $customURL)
                    .textFieldStyle(.roundedBorder)
                
                Text("Supports PNG, JPG, SVG, and other web image formats.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // Preview
            if let url = URL(string: customURL), !customURL.isEmpty {
                VStack {
                    Text("Preview:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 64, height: 64)
                    } placeholder: {
                        ProgressView()
                            .frame(width: 64, height: 64)
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            Spacer()
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                Spacer()
                Button("Apply") {
                    selectedIcon = customURL
                    iconType = .url
                    dismiss()
                }
                .disabled(customURL.isEmpty)
            }
        }
        .padding(.top, 8)
    }
    
    // File picker
    private var filePicker: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Select a local image file:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack {
                    TextField("~/Pictures/icon.png", text: $customFilePath)
                        .textFieldStyle(.roundedBorder)
                    
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.png, .jpeg, .gif, .svg, .image]
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        
                        if panel.runModal() == .OK, let url = panel.url {
                            customFilePath = url.path
                        }
                    }
                }
                
                Text("The file will be loaded from this path each time the app starts.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // Preview
            if !customFilePath.isEmpty {
                VStack {
                    Text("Preview:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let image = NSImage(contentsOfFile: NSString(string: customFilePath).expandingTildeInPath) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 64, height: 64)
                    } else {
                        VStack {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title)
                                .foregroundColor(.orange)
                            Text("File not found")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 64, height: 64)
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            Spacer()
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                Spacer()
                Button("Apply") {
                    selectedIcon = customFilePath
                    iconType = .file
                    dismiss()
                }
                .disabled(customFilePath.isEmpty)
            }
        }
        .padding(.top, 8)
    }
}

struct FolderBrowserView: View {
    let account: IMAPAccount
    @Binding var availableFolders: [String]
    @Binding var isPresented: Bool
    let onSelectFolder: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Available Folders on \(account.host)")
                .font(.headline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(availableFolders, id: \.self) { folder in
                        Button(action: {
                            onSelectFolder(folder)
                            isPresented = false
                        }) {
                            HStack {
                                Image(systemName: "folder")
                                Text(folder)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.clear)
                    }
                }
            }
            .frame(height: 400)
            .border(Color.secondary.opacity(0.2))

            Button("Cancel") {
                isPresented = false
            }
        }
        .padding()
        .frame(width: 450)
    }
}

#Preview {
    SettingsView()
}
