import Foundation
import Combine

/// Manages a virtual folder that aggregates emails from multiple real folders
class VirtualFolderManager: ObservableObject {
    @Published var emails: [Email] = []
    @Published var isLoading = false
    @Published var unreadCount: Int = 0
    @Published var lastSyncTime: Date?
    @Published var errorMessage: String?
    
    let virtualFolder: VirtualFolder
    private var sourceManagers: [EmailManager] = []
    private var cancellables = Set<AnyCancellable>()
    
    init(virtualFolder: VirtualFolder, allEmailManagers: [EmailManager]) {
        self.virtualFolder = virtualFolder
        
        // Find the EmailManagers that correspond to our sources
        for source in virtualFolder.sources {
            if let manager = allEmailManagers.first(where: { 
                $0.account.id == source.accountId && 
                $0.folderConfig.folderPath == source.folderPath 
            }) {
                sourceManagers.append(manager)
            }
        }
        
        // Subscribe to changes from all source managers
        for manager in sourceManagers {
            manager.$emails
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.aggregateEmails()
                }
                .store(in: &cancellables)
        }
        
        // Initial aggregation
        aggregateEmails()
        
        debugLog("[VirtualFolder] '\(virtualFolder.name)' initialized with \(sourceManagers.count) sources")
    }
    
    deinit {
        cancellables.removeAll()
        debugLog("[VirtualFolder] '\(virtualFolder.name)' DEINIT")
    }
    
    /// Aggregate emails from all source managers, apply filters, sort by date
    private func aggregateEmails() {
        var allEmails: [Email] = []
        
        for manager in sourceManagers {
            allEmails.append(contentsOf: manager.emails)
        }
        
        // Apply virtual folder's filters
        let filtered = allEmails.filter { virtualFolder.matchesFilters(email: $0) }
        
        // Sort by date (newest first)
        let sorted = filtered.sorted { $0.date > $1.date }
        
        // Apply max limit
        let limited: [Email]
        if virtualFolder.maxEmails > 0 {
            limited = Array(sorted.prefix(virtualFolder.maxEmails))
        } else {
            limited = sorted
        }
        
        // Update published properties
        self.emails = limited
        self.unreadCount = limited.filter { !$0.isRead }.count
        self.lastSyncTime = Date()
        
        debugLog("[VirtualFolder] '\(virtualFolder.name)' aggregated \(limited.count) emails (\(unreadCount) unread) from \(sourceManagers.count) sources")
    }
    
    /// Force refresh all source managers
    func refresh() {
        for manager in sourceManagers {
            manager.refresh()
        }
    }
    
    /// Mark email as read - delegates to the appropriate source manager
    func markAsRead(_ email: Email) {
        if let manager = findManager(for: email) {
            manager.markAsRead(email)
        }
    }
    
    /// Mark email as unread - delegates to the appropriate source manager
    func markAsUnread(_ email: Email) {
        if let manager = findManager(for: email) {
            manager.markAsUnread(email)
        }
    }
    
    /// Delete email - delegates to the appropriate source manager
    func deleteEmail(_ email: Email) {
        if let manager = findManager(for: email) {
            manager.deleteEmail(email)
        }
    }
    
    /// Find which source manager owns this email
    private func findManager(for email: Email) -> EmailManager? {
        for manager in sourceManagers {
            if manager.emails.contains(where: { $0.uid == email.uid && $0.id == email.id }) {
                return manager
            }
        }
        return nil
    }
    
    /// Get the account for an email (for reply/compose)
    func getAccount(for email: Email) -> IMAPAccount? {
        return findManager(for: email)?.account
    }
}
