import SwiftUI

struct SettingsView: View {
    @State private var config = AppConfig.load()
    @State private var selectedAccountID: UUID?
    @State private var testingConnection = false
    @State private var testMessage = ""
    @State private var showFolderBrowser = false
    @State private var availableFolders: [String] = []

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
        .frame(minWidth: 800, minHeight: 600)
        .padding()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save & Reload") {
                    saveConfig()
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Account settings
                GroupBox(label: Text("Account Settings")) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Account Name", text: $account.name)

                        TextField("IMAP Host", text: $account.host)

                        HStack {
                            TextField("Port", value: $account.port, format: .number)
                                .frame(width: 80)
                            Toggle("Use SSL", isOn: $account.useSSL)
                        }

                        TextField("Username", text: $account.username)
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
                                    .foregroundColor(testMessage.contains("Success") ? .green : .red)
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
                                FolderRowView(folder: $folder, onDelete: {
                                    account.folders.removeAll { $0.id == folder.id }
                                })
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
}

struct FolderRowView: View {
    @Binding var folder: FolderConfig
    let onDelete: () -> Void
    @State private var showingIconPicker = false

    var body: some View {
        HStack {
            Toggle(isOn: $folder.enabled) {
                HStack(spacing: 8) {
                    // Icon picker button
                    Button(action: { showingIconPicker = true }) {
                        Image(systemName: folder.icon)
                            .frame(width: 20, height: 20)
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingIconPicker) {
                        IconPickerView(selectedIcon: $folder.icon)
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

struct IconPickerView: View {
    @Binding var selectedIcon: String
    @Environment(\.dismiss) var dismiss

    let commonIcons = [
        "envelope", "tray", "paperplane", "doc.text",
        "folder", "archivebox", "star", "flag",
        "bell", "tag", "bookmark", "gear",
        "person", "briefcase", "cart", "creditcard",
        "book", "newspaper", "graduationcap", "building",
        "house", "phone", "message", "video"
    ]

    var body: some View {
        VStack(spacing: 12) {
            Text("Choose Icon")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 50))], spacing: 12) {
                ForEach(commonIcons, id: \.self) { icon in
                    Button(action: {
                        selectedIcon = icon
                        dismiss()
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: icon)
                                .font(.title2)
                                .frame(width: 40, height: 40)
                                .background(selectedIcon == icon ? Color.accentColor.opacity(0.2) : Color.clear)
                                .cornerRadius(8)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                TextField("Custom SF Symbol", text: $selectedIcon)
                    .textFieldStyle(.roundedBorder)
                Button("Done") {
                    dismiss()
                }
            }
        }
        .padding()
        .frame(width: 400, height: 350)
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
