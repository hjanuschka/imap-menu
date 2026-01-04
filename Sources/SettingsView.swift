import SwiftUI

// MARK: - Selection Types

enum SidebarSelection: Hashable {
    case account(UUID)
    case virtualFolder(UUID)
}

// MARK: - Main Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var config = AppConfig.load()
    @State private var selection: SidebarSelection?

    var body: some View {
        NavigationSplitView {
            // Sidebar
            List(selection: $selection) {
                Section("Mail Accounts") {
                    ForEach($config.accounts) { $account in
                        NavigationLink(value: SidebarSelection.account(account.id)) {
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
                        NavigationLink(value: SidebarSelection.virtualFolder(vf.id)) {
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
            switch selection {
            case .account(let accountID):
                if let index = config.accounts.firstIndex(where: { $0.id == accountID }) {
                    AccountSettingsView(account: $config.accounts[index], allAccounts: config.accounts)
                } else {
                    WelcomeView(onAddAccount: addNewAccount)
                }
            case .virtualFolder(let vfID):
                if let index = config.virtualFolders.firstIndex(where: { $0.id == vfID }) {
                    VirtualFolderSettingsView(virtualFolder: $config.virtualFolders[index], accounts: config.accounts)
                } else {
                    WelcomeView(onAddAccount: addNewAccount)
                }
            case .none:
                WelcomeView(onAddAccount: addNewAccount)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .safeAreaInset(edge: .bottom) {
            // Bottom bar with Save/Cancel buttons
            HStack {
                Spacer()
                
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
            .padding()
            .background(.bar)
        }
    }
    
    private func addNewAccount() {
        let account = IMAPAccount(name: "New Account", host: "", username: "")
        config.accounts.append(account)
        selection = .account(account.id)
    }
    
    private func addNewVirtualFolder() {
        let vf = VirtualFolder(name: "New Virtual Folder")
        config.virtualFolders.append(vf)
        selection = .virtualFolder(vf.id)
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
    @State private var showIconPicker = false
    @State private var showFilters = false
    
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
                
                // Icon settings (with picker button)
                HStack {
                    Text("Icon:")
                    
                    Button(action: { showIconPicker = true }) {
                        HStack {
                            folderIconPreview
                                .frame(width: 20, height: 20)
                            Text("Change...")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    if folder.iconType == .sfSymbol {
                        ColorPicker("", selection: Binding(
                            get: { Color(folder.nsColor) },
                            set: { folder.iconColor = $0.hexString }
                        ))
                        .labelsHidden()
                        .frame(width: 40)
                    }
                    
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
                
                // Filters section
                DisclosureGroup("Filters (\(folder.filterGroups.count) groups)", isExpanded: $showFilters) {
                    FilterGroupEditor(
                        filterGroups: $folder.filterGroups,
                        groupLogic: $folder.groupLogic
                    )
                }
                .padding(.top, 8)
                
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
                folderIconPreview
                    .frame(width: 20, height: 20)
                
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
        .sheet(isPresented: $showIconPicker) {
            IconPickerView(
                icon: $folder.icon,
                iconType: $folder.iconType,
                iconColor: $folder.iconColor
            )
        }
    }
    
    @ViewBuilder
    private var folderIconPreview: some View {
        switch folder.iconType {
        case .sfSymbol:
            Image(systemName: folder.icon)
                .foregroundColor(Color(folder.nsColor))
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
    
    @State private var showIconPicker = false
    
    var body: some View {
        Form {
            // Basic Settings
            Section {
                TextField("Name", text: $virtualFolder.name)
                    .textFieldStyle(.roundedBorder)
                
                Toggle("Enabled", isOn: $virtualFolder.enabled)
                
                // Icon picker (same as regular folders)
                HStack {
                    Text("Icon:")
                    
                    Button(action: { showIconPicker = true }) {
                        HStack {
                            iconPreview
                                .frame(width: 24, height: 24)
                            Text("Change...")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    if virtualFolder.iconType == .sfSymbol {
                        ColorPicker("", selection: Binding(
                            get: { Color(virtualFolder.nsColor) },
                            set: { virtualFolder.iconColor = $0.hexString }
                        ))
                        .labelsHidden()
                    }
                }
                
                Picker("Max Emails", selection: $virtualFolder.maxEmails) {
                    Text("50").tag(50)
                    Text("100").tag(100)
                    Text("200").tag(200)
                    Text("500").tag(500)
                }
                
                Picker("Popover Size", selection: $virtualFolder.popoverWidth) {
                    Text("Small").tag(FolderConfig.PopoverWidth.small)
                    Text("Medium").tag(FolderConfig.PopoverWidth.medium)
                    Text("Large").tag(FolderConfig.PopoverWidth.large)
                }
            } header: {
                Label("Settings", systemImage: "gear")
            }
            
            // Email Sources
            Section {
                if accounts.isEmpty {
                    Text("No accounts configured. Add an account first.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(accounts) { account in
                        DisclosureGroup {
                            if account.folders.filter({ $0.enabled }).isEmpty {
                                Text("No enabled folders in this account")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            } else {
                                ForEach(account.folders.filter { $0.enabled }) { folder in
                                    Toggle(isOn: sourceBinding(accountId: account.id, folderPath: folder.folderPath)) {
                                        HStack {
                                            Image(systemName: folder.icon)
                                                .foregroundColor(Color(folder.nsColor))
                                            VStack(alignment: .leading) {
                                                Text(folder.name)
                                                Text(folder.folderPath)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    .padding(.leading, 8)
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: accountIcon(account))
                                    .foregroundColor(accountColor(account))
                                Text(account.name)
                                    .fontWeight(.medium)
                                
                                let sourceCount = virtualFolder.sources.filter { $0.accountId == account.id }.count
                                if sourceCount > 0 {
                                    Text("\(sourceCount) selected")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: {
                Label("Email Sources (\(virtualFolder.sources.count) selected)", systemImage: "tray.2")
            }
            
            // Filters (using shared component)
            Section {
                FilterGroupEditor(
                    filterGroups: $virtualFolder.filterGroups,
                    groupLogic: $virtualFolder.groupLogic
                )
            } header: {
                Label("Filters (Optional)", systemImage: "line.3.horizontal.decrease.circle")
            } footer: {
                Text("Filters are applied to emails from all selected sources. Only matching emails will be shown.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showIconPicker) {
            IconPickerView(
                icon: $virtualFolder.icon,
                iconType: $virtualFolder.iconType,
                iconColor: $virtualFolder.iconColor
            )
        }
    }
    
    @ViewBuilder
    private var iconPreview: some View {
        switch virtualFolder.iconType {
        case .sfSymbol:
            Image(systemName: virtualFolder.icon)
                .foregroundColor(Color(virtualFolder.nsColor))
        case .url:
            AsyncImage(url: URL(string: virtualFolder.icon)) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Image(systemName: "photo")
                    .foregroundColor(.secondary)
            }
        case .file:
            if let nsImage = NSImage(contentsOfFile: NSString(string: virtualFolder.icon).expandingTildeInPath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "doc")
                    .foregroundColor(.secondary)
            }
        }
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
    
    private func accountIcon(_ account: IMAPAccount) -> String {
        switch account.accountType {
        case .imap: return "envelope"
        case .gmailAppPassword, .gmailOAuth2: return "envelope.badge"
        }
    }
    
    private func accountColor(_ account: IMAPAccount) -> Color {
        switch account.accountType {
        case .imap: return .blue
        case .gmailAppPassword, .gmailOAuth2: return .red
        }
    }
}

// MARK: - Icon Picker View (shared between folders and virtual folders)

struct IconPickerView: View {
    @Binding var icon: String
    @Binding var iconType: FolderConfig.IconType
    @Binding var iconColor: String
    @Environment(\.dismiss) var dismiss
    
    @State private var selectedTab = 0
    @State private var searchText = ""
    @State private var customURL = ""
    @State private var customFilePath = ""
    
    let sfSymbols: [String] = [
        "envelope", "envelope.fill", "envelope.badge", "envelope.open",
        "tray", "tray.fill", "tray.2", "tray.full",
        "folder", "folder.fill", "folder.badge.plus",
        "star", "star.fill", "flag", "flag.fill",
        "bell", "bell.fill", "bolt", "bolt.fill",
        "person", "person.fill", "person.2", "person.crop.circle",
        "bubble.left", "bubble.right", "quote.bubble",
        "paperplane", "paperplane.fill",
        "doc", "doc.fill", "doc.text", "doc.text.fill",
        "calendar", "clock", "alarm",
        "tag", "tag.fill", "bookmark", "bookmark.fill",
        "heart", "heart.fill", "hand.thumbsup", "hand.thumbsdown",
        "checkmark.circle", "xmark.circle", "exclamationmark.triangle",
        "globe", "network", "antenna.radiowaves.left.and.right",
        "building.2", "house", "briefcase",
        "cart", "creditcard", "dollarsign.circle",
        "gamecontroller", "headphones", "tv",
        "camera", "photo", "video",
        "link", "paperclip", "pin",
        "lock", "key", "shield"
    ]
    
    var filteredSymbols: [String] {
        if searchText.isEmpty {
            return sfSymbols
        }
        return sfSymbols.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Choose Icon")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            
            // Tab selector
            Picker("", selection: $selectedTab) {
                Text("SF Symbols").tag(0)
                Text("Image URL").tag(1)
                Text("Local File").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            
            Divider()
                .padding(.top, 8)
            
            // Content
            switch selectedTab {
            case 0:
                sfSymbolsPicker
            case 1:
                urlPicker
            case 2:
                filePicker
            default:
                EmptyView()
            }
        }
        .frame(width: 400, height: 450)
        .onAppear {
            selectedTab = iconType == .sfSymbol ? 0 : (iconType == .url ? 1 : 2)
            customURL = iconType == .url ? icon : ""
            customFilePath = iconType == .file ? icon : ""
        }
    }
    
    private var sfSymbolsPicker: some View {
        VStack(spacing: 8) {
            // Search
            TextField("Search symbols...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.top, 8)
            
            // Grid
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 50))], spacing: 8) {
                    ForEach(filteredSymbols, id: \.self) { symbol in
                        Button(action: {
                            icon = symbol
                            iconType = .sfSymbol
                            dismiss()
                        }) {
                            VStack(spacing: 4) {
                                Image(systemName: symbol)
                                    .font(.title2)
                                    .frame(width: 40, height: 40)
                                    .background(icon == symbol && iconType == .sfSymbol ? Color.accentColor.opacity(0.2) : Color.clear)
                                    .cornerRadius(8)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(symbol)
                    }
                }
                .padding()
            }
            
            // Color picker
            HStack {
                Text("Color:")
                ColorPicker("", selection: Binding(
                    get: { Color(NSColor(hex: iconColor) ?? .systemBlue) },
                    set: { iconColor = $0.hexString }
                ))
                .labelsHidden()
                
                Spacer()
                
                // Preview
                Image(systemName: icon)
                    .font(.title)
                    .foregroundColor(Color(NSColor(hex: iconColor) ?? .systemBlue))
            }
            .padding()
        }
    }
    
    private var urlPicker: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter an image URL:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextField("https://example.com/icon.png", text: $customURL)
                    .textFieldStyle(.roundedBorder)
            }
            .padding()
            
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
                Spacer()
                Button("Apply") {
                    icon = customURL
                    iconType = .url
                    dismiss()
                }
                .disabled(customURL.isEmpty)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }
    
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
                        panel.allowedContentTypes = [.png, .jpeg, .gif, .image]
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        
                        if panel.runModal() == .OK, let url = panel.url {
                            customFilePath = url.path
                        }
                    }
                }
            }
            .padding()
            
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
                Spacer()
                Button("Apply") {
                    icon = customFilePath
                    iconType = .file
                    dismiss()
                }
                .disabled(customFilePath.isEmpty)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }
}

// MARK: - Filter Group Editor (shared between folders and virtual folders)

struct FilterGroupEditor: View {
    @Binding var filterGroups: [FilterGroup]
    @Binding var groupLogic: FolderConfig.FilterLogic
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Group logic
            Picker("When multiple groups:", selection: $groupLogic) {
                Text("Match ANY group (OR)").tag(FolderConfig.FilterLogic.or)
                Text("Match ALL groups (AND)").tag(FolderConfig.FilterLogic.and)
            }
            
            Divider()
            
            // Filter groups
            ForEach($filterGroups) { $group in
                FilterGroupRow(group: $group, onDelete: {
                    filterGroups.removeAll { $0.id == group.id }
                })
            }
            
            // Add group button
            Button(action: {
                filterGroups.append(FilterGroup(name: "New Filter Group", filters: [], logic: .or, enabled: true))
            }) {
                Label("Add Filter Group", systemImage: "plus.circle")
            }
        }
    }
}

struct FilterGroupRow: View {
    @Binding var group: FilterGroup
    let onDelete: () -> Void
    
    @State private var isExpanded = true
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                // Group settings
                HStack {
                    TextField("Group Name", text: $group.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    
                    Picker("", selection: $group.logic) {
                        Text("OR").tag(FilterGroup.GroupLogic.or)
                        Text("AND").tag(FilterGroup.GroupLogic.and)
                    }
                    .frame(width: 80)
                    
                    Toggle("Enabled", isOn: $group.enabled)
                        .toggleStyle(.checkbox)
                    
                    Spacer()
                    
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                
                // Filters
                ForEach($group.filters) { $filter in
                    FilterRow(filter: $filter, onDelete: {
                        group.filters.removeAll { $0.id == filter.id }
                    })
                }
                
                // Add filter button
                Button(action: {
                    group.filters.append(EmailFilter(
                        id: UUID(),
                        filterType: .include,
                        field: .subject,
                        matchType: .contains,
                        pattern: ""
                    ))
                }) {
                    Label("Add Filter", systemImage: "plus")
                        .font(.caption)
                }
                .padding(.leading, 16)
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Image(systemName: group.enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(group.enabled ? .green : .secondary)
                Text(group.name)
                    .fontWeight(.medium)
                Text("(\(group.filters.count) filters)")
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct FilterRow: View {
    @Binding var filter: EmailFilter
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $filter.filterType) {
                Text("Include").tag(EmailFilter.FilterType.include)
                Text("Exclude").tag(EmailFilter.FilterType.exclude)
            }
            .frame(width: 90)
            
            Picker("", selection: $filter.field) {
                ForEach(EmailFilter.MatchField.allCases, id: \.self) { field in
                    Text(field.rawValue).tag(field)
                }
            }
            .frame(width: 100)
            
            Picker("", selection: $filter.matchType) {
                ForEach(EmailFilter.MatchType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .frame(width: 100)
            
            TextField("Pattern", text: $filter.pattern)
                .textFieldStyle(.roundedBorder)
            
            Toggle("", isOn: $filter.enabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
            
            Button(action: onDelete) {
                Image(systemName: "minus.circle")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.leading, 16)
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
