import SwiftUI

/// Content view for virtual folder popover - similar to ContentView but uses VirtualFolderManager
struct VirtualFolderContentView: View {
    @ObservedObject var manager: VirtualFolderManager
    @State private var selectedEmail: Email?
    @State private var searchText = ""
    @State private var loadedEmail: Email?
    @State private var isLoading = false
    
    var filteredEmails: [Email] {
        if searchText.isEmpty {
            return manager.emails
        }
        return manager.emails.filter { email in
            email.subject.localizedCaseInsensitiveContains(searchText) ||
            email.from.localizedCaseInsensitiveContains(searchText) ||
            email.preview.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if selectedEmail != nil {
                // Detail view
                detailView
            } else {
                // List view
                listView
            }
        }
        .background(Color.white)
    }
    
    // MARK: - List View
    
    private var listView: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                // Virtual folder icon and name
                Image(systemName: manager.virtualFolder.icon)
                    .foregroundColor(Color(manager.virtualFolder.nsColor))
                Text(manager.virtualFolder.name)
                    .font(.headline)
                
                Spacer()
                
                // Search
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 100)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(6)
                
                // Unread badge
                if manager.unreadCount > 0 {
                    Text("\(manager.unreadCount)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.blue)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Email list
            if filteredEmails.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(searchText.isEmpty ? "No emails" : "No matching emails")
                        .foregroundColor(.secondary)
                    Text("\(manager.virtualFolder.sources.count) sources configured")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredEmails) { email in
                            VirtualEmailRow(
                                email: email,
                                manager: manager,
                                onSelect: { selectedEmail = email }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            
            // Footer
            Divider()
            HStack {
                if let syncTime = manager.lastSyncTime {
                    Text("Updated \(syncTime, formatter: relativeFormatter)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { manager.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                
                Button(action: { openSettings() }) {
                    Image(systemName: "gear")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
    
    // MARK: - Detail View
    
    private var detailView: some View {
        VStack(spacing: 0) {
            // Header with back button
            HStack {
                Button(action: { selectedEmail = nil; loadedEmail = nil }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                // Action buttons
                if let email = selectedEmail {
                    HStack(spacing: 12) {
                        Button(action: { toggleRead(email) }) {
                            Image(systemName: email.isRead ? "envelope.badge" : "envelope.open")
                                .foregroundColor(email.isRead ? .orange : .blue)
                        }
                        .buttonStyle(.plain)
                        .help(email.isRead ? "Mark as Unread" : "Mark as Read")
                        
                        Button(action: { manager.deleteEmail(email); selectedEmail = nil }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Delete")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Email content
            if let email = selectedEmail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(email.subject.isEmpty ? "No Subject" : email.subject)
                            .font(.headline)
                        
                        HStack {
                            // Sender avatar
                            Circle()
                                .fill(Color.blue.opacity(0.2))
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Text(String(email.fromName.first ?? email.from.first ?? "?").uppercased())
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.blue)
                                )
                            
                            VStack(alignment: .leading) {
                                Text(email.fromName.isEmpty ? email.from : email.fromName)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text(email.date, formatter: dateFormatter)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Divider()
                        
                        // Body - show preview for now (full body would need account reference)
                        if !email.preview.isEmpty {
                            Text(email.preview)
                                .font(.body)
                        } else {
                            Text("Email body not available in virtual view")
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                }
            }
        }
    }
    
    private func toggleRead(_ email: Email) {
        if email.isRead {
            manager.markAsUnread(email)
        } else {
            manager.markAsRead(email)
        }
    }
    
    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    
    private var relativeFormatter: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }
    
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }
}

// MARK: - Virtual Email Row

struct VirtualEmailRow: View {
    let email: Email
    let manager: VirtualFolderManager
    let onSelect: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 8) {
            // Unread indicator
            Circle()
                .fill(email.isRead ? Color.clear : Color.blue)
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 2) {
                // Sender
                Text(email.fromName.isEmpty ? email.from : email.fromName)
                    .font(.system(size: 13, weight: email.isRead ? .regular : .semibold))
                    .lineLimit(1)
                
                // Subject
                Text(email.subject.isEmpty ? "No Subject" : email.subject)
                    .font(.system(size: 12))
                    .foregroundColor(email.isRead ? .secondary : .primary)
                    .lineLimit(1)
                
                // Preview
                if !email.preview.isEmpty {
                    Text(email.preview)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Action buttons on hover
            if isHovered {
                HStack(spacing: 4) {
                    Button(action: { toggleRead() }) {
                        Image(systemName: email.isRead ? "envelope.badge" : "envelope.open")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(email.isRead ? .orange : .blue)
                    
                    Button(action: { manager.deleteEmail(email) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                }
            }
            
            // Date
            Text(formatDate(email.date))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.gray.opacity(0.1) : Color.clear)
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
    }
    
    private func toggleRead() {
        if email.isRead {
            manager.markAsUnread(email)
        } else {
            manager.markAsRead(email)
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
