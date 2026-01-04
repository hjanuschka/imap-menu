import SwiftUI

// MARK: - Main Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var config = AppConfig.load()
    @State private var selectedAccountID: UUID?
    @State private var selectedVirtualFolderID: UUID?
    @State private var selectedTab = 0

    var body: some View {
        NavigationSplitView {
            // Sidebar
            List(selection: $selectedAccountID) {
                Section("Mail Accounts") {
                    ForEach($config.accounts) { $account in
                        NavigationLink(value: account.id) {
                            AccountSidebarRow(account: account)
                        }
                    }
                    .onDelete { indexSet in
                        config.accounts.remove(atOffsets: indexSet)
                    }
                    .onMove { from, to in
                        config.accounts.move(fromOffsets: from, toOffset: to)
                    }
                    
                    Button(action: addNewAccount) {
                        Label("Add Account", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
                
                Section("Virtual Folders") {
                    ForEach($config.virtualFolders) { $vf in
                        NavigationLink(value: vf.id) {
                            Label(vf.name, systemImage: vf.icon)
                                .foregroundColor(Color(vf.nsColor))
                        }
                    }
                    .onDelete { indexSet in
                        config.virtualFolders.remove(atOffsets: indexSet)
                    }
                    
                    Button(action: addNewVirtualFolder) {
                        Label("Add Virtual Folder", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200)

        } detail: {
            // Detail View
            if let accountID = selectedAccountID,
               let index = config.accounts.firstIndex(where: { $0.id == accountID }) {
                AccountSettingsView(account: $config.accounts[index], allAccounts: config.accounts)
            } else if let vfID = selectedVirtualFolderID,
                      let index = config.virtualFolders.firstIndex(where: { $0.id == vfID }) {
                VirtualFolderSettingsView(virtualFolder: $config.virtualFolders[index], accounts: config.accounts)
            } else {
                WelcomeView(onAddAccount: addNewAccount)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Save") {
                    saveAndClose()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .onChange(of: selectedAccountID) { _ in
            selectedVirtualFolderID = nil
        }
    }
    
    private func addNewAccount() {
        let account = IMAPAccount(name: "New Account", host: "", username: "")
        config.accounts.append(account)
        selectedAccountID = account.id
    }
    
    private func addNewVirtualFolder() {
        let vf = VirtualFolder(name: "New Virtual Folder")
        config.virtualFolders.append(vf)
        selectedVirtualFolderID = vf.id
    }
    
    private func saveAndClose() {
        config.save()
        NotificationCenter.default.post(name: NSNotification.Name("RefreshEmails"), object: nil)
        dismiss()
    }
}

// MARK: - Sidebar Row

struct AccountSidebarRow: View {
    let account: IMAPAccount
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: accountIcon)
                .foregroundColor(accountColor)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .fontWeight(.medium)
                Text(account.username.isEmpty ? "Not configured" : account.username)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
    
    private var accountIcon: String {
        switch account.accountType {
        case .imap: return "envelope"
        case .gmailAppPassword, .gmailOAuth2: return "envelope.badge"
        }
    }
    
    private var accountColor: Color {
        switch account.accountType {
        case .imap: return .blue
        case .gmailAppPassword, .gmailOAuth2: return .red
        }
    }
}

// MARK: - Welcome View

struct WelcomeView: View {
    let onAddAccount: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope.open")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("Welcome to IMAPMenu")
                .font(.title)
            
            Text("Add an email account to get started")
                .foregroundColor(.secondary)
            
            Button(action: onAddAccount) {
                Label("Add Account", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Account Settings View

struct AccountSettingsView: View {
    @Binding var account: IMAPAccount
    let allAccounts: [IMAPAccount]
    
    @State private var testingConnection = false
    @State private var testResult: TestResult?
    @State private var showFolderBrowser = false
    @State private var availableFolders: [String] = []
    @State private var expandedSections: Set<String> = ["connection", "folders"]
    
    enum TestResult {
        case success(String)
        case failure(String)
    }
    
    var body: some View {
        Form {
            // Account Type Section
            Section {
                Picker("Account Type", selection: $account.accountType) {
                    ForEach(IMAPAccount.AccountType.allCases, id: \.self) { type in
                        Label(type.rawValue, systemImage: typeIcon(type)).tag(type)
                    }
                }
                .onChange(of: account.accountType) { newType in
                    if (newType == .gmailAppPassword || newType == .gmailOAuth2) && account.host.isEmpty {
                        account.host = "imap.gmail.com"
                        account.port = 993
                        account.useSSL = true
                        account.smtpHost = "smtp.gmail.com"
                        account.smtpPort = 587
                        account.smtpUseSSL = true
                    }
                }
                
                TextField("Account Name", text: $account.name)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Label("Account", systemImage: "person.crop.circle")
            }
            
            // Gmail Help
            if account.accountType == .gmailAppPassword {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("How to get an App Password:", systemImage: "questionmark.circle")
                            .font(.headline)
                        
                        Text("1. Go to your Google Account settings")
                        Text("2. Enable 2-Step Verification if not already")
                        Text("3. Search for 'App passwords'")
                        Text("4. Generate a new app password for 'Mail'")
                        Text("5. Copy the 16-character password below")
                        
                        Link(destination: URL(string: "https://myaccount.google.com/apppasswords")!) {
                            Label("Open Google App Passwords", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
                }
            }
            
            // Connection Section
            Section {
                HStack {
                    TextField("Server", text: $account.host)
                        .textFieldStyle(.roundedBorder)
                        .disabled(account.accountType != .imap)
                    
                    TextField("Port", value: $account.port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .disabled(account.accountType != .imap)
                    
                    Toggle("SSL", isOn: $account.useSSL)
                        .toggleStyle(.checkbox)
                        .disabled(account.accountType != .imap)
                }
                
                TextField("Email / Username", text: $account.username)
                    .textFieldStyle(.roundedBorder)
                
                if account.accountType != .gmailOAuth2 {
                    SecureField(account.accountType == .gmailAppPassword ? "App Password" : "Password", text: $account.password)
                        .textFieldStyle(.roundedBorder)
                }
                
                // Test Connection
                HStack {
                    Button(action: testConnection) {
                        if testingConnection {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .disabled(testingConnection || account.host.isEmpty || account.username.isEmpty)
                    
                    if let result = testResult {
                        switch result {
                        case .success(let msg):
                            Label(msg, systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        case .failure(let msg):
                            Label(msg, systemImage: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                    }
                }
            } header: {
                Label("IMAP Connection", systemImage: "server.rack")
            }
            
            // SMTP Section
            Section {
                HStack {
                    TextField("SMTP Server", text: $account.smtpHost)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Port", value: $account.smtpPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    
                    Toggle("SSL", isOn: $account.smtpUseSSL)
                        .toggleStyle(.checkbox)
                }
                
                TextField("From Email", text: $account.fromEmail)
                    .textFieldStyle(.roundedBorder)
                
                TextField("From Name", text: $account.fromName)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Label("SMTP (Sending)", systemImage: "paperplane")
            }
            
            // Folders Section
            Section {
                ForEach($account.folders) { $folder in
                    FolderSettingsRow(folder: $folder, onDelete: {
                        account.folders.removeAll { $0.id == folder.id }
                    })
                }
                .onDelete { indexSet in
                    account.folders.remove(atOffsets: indexSet)
                }
                .onMove { from, to in
                    account.folders.move(fromOffsets: from, toOffset: to)
                }
                
                Button(action: { showFolderBrowser = true }) {
                    Label("Browse Folders on Server", systemImage: "folder.badge.plus")
                }
                .disabled(account.host.isEmpty)
            } header: {
                Label("Monitored Folders", systemImage: "folder")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showFolderBrowser) {
            FolderBrowserSheet(account: account, onSelect: { folder in
                account.folders.append(FolderConfig(name: folder, folderPath: folder))
            })
        }
    }
    
    private func typeIcon(_ type: IMAPAccount.AccountType) -> String {
        switch type {
        case .imap: return "envelope"
        case .gmailAppPassword: return "key"
        case .gmailOAuth2: return "lock.shield"
        }
    }
    
    private func testConnection() {
        testingConnection = true
        testResult = nil
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let config: IMAPConfig
                if account.accountType == .gmailOAuth2 {
                    guard let tokens = OAuth2Manager.shared.loadTokens(for: account.id.uuidString) else {
                        throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
                    }
                    config = IMAPConfig(host: account.host, port: account.port, username: account.username, accessToken: tokens.accessToken, useSSL: account.useSSL)
                } else {
                    config = IMAPConfig(host: account.host, port: account.port, username: account.username, password: account.password, useSSL: account.useSSL)
                }
                
                let connection = IMAPConnection(config: config)
                try connection.connect()
                connection.disconnect()
                
                DispatchQueue.main.async {
                    testingConnection = false
                    testResult = .success("Connected!")
                }
            } catch {
                DispatchQueue.main.async {
                    testingConnection = false
                    testResult = .failure(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Folder Settings Row

struct FolderSettingsRow: View {
    @Binding var folder: FolderConfig
    let onDelete: () -> Void
    
    @State private var isExpanded = false
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                // Basic settings
                HStack {
                    TextField("Display Name", text: $folder.name)
                        .textFieldStyle(.roundedBorder)
                    
                    Toggle("Enabled", isOn: $folder.enabled)
                        .toggleStyle(.checkbox)
                }
                
                // Icon settings
                HStack {
                    TextField("Icon", text: $folder.icon)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    
                    Image(systemName: folder.icon)
                        .foregroundColor(Color(folder.nsColor))
                    
                    ColorPicker("", selection: Binding(
                        get: { Color(folder.nsColor) },
                        set: { folder.iconColor = $0.hexString }
                    ))
                    .labelsHidden()
                    .frame(width: 40)
                    
                    Spacer()
                    
                    Picker("Size", selection: $folder.popoverWidth) {
                        Text("S").tag(FolderConfig.PopoverWidth.small)
                        Text("M").tag(FolderConfig.PopoverWidth.medium)
                        Text("L").tag(FolderConfig.PopoverWidth.large)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 100)
                }
                
                // Fetch settings
                HStack {
                    Picker("Max Emails", selection: $folder.maxEmails) {
                        Text("50").tag(50)
                        Text("100").tag(100)
                        Text("200").tag(200)
                        Text("500").tag(500)
                    }
                    .frame(width: 150)
                    
                    Picker("Days to Fetch", selection: $folder.daysToFetch) {
                        Text("All").tag(0)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .frame(width: 150)
                }
                
                // Delete button
                HStack {
                    Spacer()
                    Button(role: .destructive, action: onDelete) {
                        Label("Remove Folder", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 8)
        } label: {
            HStack {
                Image(systemName: folder.icon)
                    .foregroundColor(Color(folder.nsColor))
                    .frame(width: 20)
                
                VStack(alignment: .leading) {
                    Text(folder.name)
                        .fontWeight(.medium)
                    Text(folder.folderPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if !folder.enabled {
                    Text("Disabled")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
            }
        }
    }
}

// MARK: - Folder Browser Sheet

struct FolderBrowserSheet: View {
    let account: IMAPAccount
    let onSelect: (String) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [String] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var searchText = ""
    
    var filteredFolders: [String] {
        if searchText.isEmpty {
            return folders
        }
        return folders.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Select Folder")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            
            Divider()
            
            // Search
            TextField("Search folders...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding()
            
            // Content
            if isLoading {
                Spacer()
                ProgressView("Loading folders...")
                Spacer()
            } else if let error = error {
                Spacer()
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List(filteredFolders, id: \.self) { folder in
                    Button(action: {
                        onSelect(folder)
                        dismiss()
                    }) {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundColor(.blue)
                            Text(folder)
                            Spacer()
                            Image(systemName: "plus.circle")
                                .foregroundColor(.green)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 400, height: 500)
        .onAppear(perform: loadFolders)
    }
    
    private func loadFolders() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let config = IMAPConfig(host: account.host, port: account.port, username: account.username, password: account.password, useSSL: account.useSSL)
                let connection = IMAPConnection(config: config)
                try connection.connect()
                let folderList = try connection.listFolders()
                connection.disconnect()
                
                DispatchQueue.main.async {
                    folders = folderList.sorted()
                    isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Virtual Folder Settings View

struct VirtualFolderSettingsView: View {
    @Binding var virtualFolder: VirtualFolder
    let accounts: [IMAPAccount]
    
    var body: some View {
        Form {
            Section {
                TextField("Name", text: $virtualFolder.name)
                    .textFieldStyle(.roundedBorder)
                
                Toggle("Enabled", isOn: $virtualFolder.enabled)
                
                HStack {
                    TextField("Icon", text: $virtualFolder.icon)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    
                    Image(systemName: virtualFolder.icon)
                        .foregroundColor(Color(virtualFolder.nsColor))
                    
                    ColorPicker("", selection: Binding(
                        get: { Color(virtualFolder.nsColor) },
                        set: { virtualFolder.iconColor = $0.hexString }
                    ))
                    .labelsHidden()
                }
                
                Picker("Max Emails", selection: $virtualFolder.maxEmails) {
                    Text("50").tag(50)
                    Text("100").tag(100)
                    Text("200").tag(200)
                    Text("500").tag(500)
                }
            } header: {
                Label("Settings", systemImage: "gear")
            }
            
            Section {
                Text("Select folders to aggregate:")
                    .foregroundColor(.secondary)
                
                ForEach(accounts) { account in
                    DisclosureGroup {
                        ForEach(account.folders.filter { $0.enabled }) { folder in
                            Toggle(isOn: sourceBinding(accountId: account.id, folderPath: folder.folderPath)) {
                                HStack {
                                    Image(systemName: folder.icon)
                                        .foregroundColor(Color(folder.nsColor))
                                    Text(folder.name)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.leading, 8)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle")
                                .foregroundColor(.blue)
                            Text(account.name)
                                .fontWeight(.medium)
                        }
                    }
                }
            } header: {
                Label("Email Sources", systemImage: "tray.2")
            }
            
            Section {
                Picker("Filter Logic", selection: $virtualFolder.groupLogic) {
                    Text("Match ANY filter (OR)").tag(FolderConfig.FilterLogic.or)
                    Text("Match ALL filters (AND)").tag(FolderConfig.FilterLogic.and)
                }
                
                ForEach($virtualFolder.filterGroups) { $group in
                    DisclosureGroup {
                        ForEach(group.filters, id: \.id) { filter in
                            Text("\(filter.field.rawValue) \(filter.matchType.rawValue) '\(filter.pattern)'")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }
                        
                        Button("Add Filter") {
                            var g = group
                            g.filters.append(EmailFilter(id: UUID(), filterType: .include, field: .subject, matchType: .contains, pattern: ""))
                            if let idx = virtualFolder.filterGroups.firstIndex(where: { $0.id == group.id }) {
                                virtualFolder.filterGroups[idx] = g
                            }
                        }
                    } label: {
                        HStack {
                            Toggle("", isOn: $group.enabled)
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                            Text(group.name)
                        }
                    }
                }
                
                Button("Add Filter Group") {
                    virtualFolder.filterGroups.append(FilterGroup(name: "New Filter", filters: [], logic: .and, enabled: true))
                }
            } header: {
                Label("Filters (Optional)", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
        .formStyle(.grouped)
    }
    
    private func sourceBinding(accountId: UUID, folderPath: String) -> Binding<Bool> {
        Binding(
            get: {
                virtualFolder.sources.contains { $0.accountId == accountId && $0.folderPath == folderPath }
            },
            set: { newValue in
                if newValue {
                    virtualFolder.sources.append(FolderSource(accountId: accountId, folderPath: folderPath))
                } else {
                    virtualFolder.sources.removeAll { $0.accountId == accountId && $0.folderPath == folderPath }
                }
            }
        )
    }
}

// MARK: - Color Extension

extension Color {
    var hexString: String {
        guard let components = NSColor(self).usingColorSpace(.deviceRGB)?.cgColor.components, components.count >= 3 else {
            return "#007AFF"
        }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}
