import Foundation
import UserNotifications

class NotificationManager {
    static let shared = NotificationManager()
    
    private var hasPermission = false
    private var lastNotifiedUIDs: [String: Set<UInt32>] = [:] // folder -> UIDs we've notified about
    
    private init() {
        requestPermission()
    }
    
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                self.hasPermission = granted
                if granted {
                    debugLog("[Notifications] Permission granted")
                } else if let error = error {
                    debugLog("[Notifications] Permission error: \(error)")
                }
            }
        }
    }
    
    /// Notify about new unread emails that we haven't notified about before
    func notifyNewEmails(_ emails: [Email], folderName: String, folderKey: String) {
        guard hasPermission else { return }
        
        // Get previously notified UIDs for this folder
        let previousUIDs = lastNotifiedUIDs[folderKey] ?? []
        
        // Find new unread emails we haven't notified about
        let newUnread = emails.filter { !$0.isRead && !previousUIDs.contains($0.uid) }
        
        guard !newUnread.isEmpty else { return }
        
        // Update tracked UIDs
        let allUIDs = Set(emails.map { $0.uid })
        lastNotifiedUIDs[folderKey] = allUIDs
        
        // Don't notify on first load (when previousUIDs was empty)
        guard !previousUIDs.isEmpty else {
            debugLog("[Notifications] First load for \(folderName), skipping notification")
            return
        }
        
        // Send notification
        if newUnread.count == 1, let email = newUnread.first {
            sendNotification(
                title: "New email in \(folderName)",
                body: "\(email.fromName): \(email.subject)",
                identifier: "\(folderKey)-\(email.uid)"
            )
        } else {
            sendNotification(
                title: "New emails in \(folderName)",
                body: "\(newUnread.count) new messages",
                identifier: "\(folderKey)-batch-\(Date().timeIntervalSince1970)"
            )
        }
    }
    
    private func sendNotification(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Deliver immediately
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                debugLog("[Notifications] Failed to send: \(error)")
            } else {
                debugLog("[Notifications] Sent: \(title)")
            }
        }
    }
    
    /// Clear tracking for a folder (e.g., when folder is removed)
    func clearFolder(_ folderKey: String) {
        lastNotifiedUIDs.removeValue(forKey: folderKey)
    }
}
