import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var config = AppConfig.load()
    @State private var selectedAccountID: UUID?
    @State private var testingConnection = false
    @State private var testMessage = ""
    @State private var showFolderBrowser = false
    @State private var availableFolders: [String] = []
    @State private var hasUnsavedChanges = false

    var body: some View {
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
    
    private func saveConfig() {
        config.save()
        NotificationCenter.default.post(name: NSNotification.Name("RefreshEmails"), object: nil)
        testMessage = "Configuration saved and reloaded"
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Account settings
                GroupBox(label: Text("IMAP Settings (Receiving)")) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Account Name", text: $account.name)

                        TextField("IMAP Host", text: $account.host)

                        HStack {
                            TextField("Port", value: $account.port, format: .number)
                                .frame(width: 80)
                            Toggle("Use SSL", isOn: $account.useSSL)
                        }

                        TextField("Username / Email", text: $account.username)
                            .textContentType(.username)

                        SecureField("Password", text: $account.password)
                            .textContentType(.password)

                        HStack {
                            Button("Test Connection") {
                                testConnection()
                            }
                            .disabled(testingConnection || account.host.isEmpty)

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
                let config = IMAPConfig(
                    host: account.host,
                    port: account.port,
                    username: account.username,
                    password: account.password,
                    useSSL: account.useSSL
                )
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

    private func browseFolders() {
        testMessage = "Loading folders..."

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let config = IMAPConfig(
                    host: account.host,
                    port: account.port,
                    username: account.username,
                    password: account.password,
                    useSSL: account.useSSL
                )
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
                    fromName: account.name
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

    var body: some View {
        HStack {
            Toggle(isOn: $folder.enabled) {
                HStack(spacing: 8) {
                    // Icon picker button
                    Button(action: { showingIconPicker = true }) {
                        Image(systemName: folder.icon)
                            .frame(width: 20, height: 20)
                            .foregroundColor(iconColor)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingIconPicker) {
                        IconPickerView(selectedIcon: $folder.icon)
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
    @Environment(\.dismiss) var dismiss
    @State private var searchText = ""

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
            HStack {
                Text("Choose Icon")
                    .font(.headline)
                Spacer()
                Text("\(filteredIcons.count) icons")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

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
            }
            .padding(8)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 55))], spacing: 8) {
                    ForEach(filteredIcons, id: \.self) { icon in
                        Button(action: {
                            selectedIcon = icon
                            dismiss()
                        }) {
                            VStack(spacing: 2) {
                                Image(systemName: icon)
                                    .font(.title3)
                                    .frame(width: 44, height: 44)
                                    .background(selectedIcon == icon ? Color.accentColor.opacity(0.2) : Color.clear)
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

            Divider()

            HStack {
                Text("Custom:")
                    .foregroundColor(.secondary)
                TextField("SF Symbol name", text: $selectedIcon)
                    .textFieldStyle(.roundedBorder)
                Button("Done") {
                    dismiss()
                }
            }
        }
        .padding()
        .frame(width: 550, height: 550)
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
