import SwiftUI
import Combine

@main
struct IMAPMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }

    init() {
        // Ensure settings can be opened programmatically
    }
}

// Represents one menubar item for one folder
class FolderMenuItem {
    let statusItem: NSStatusItem
    let popover: NSPopover
    let emailManager: EmailManager
    var cancellables = Set<AnyCancellable>()

    init(account: IMAPAccount, folderConfig: FolderConfig) {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Create email manager
        emailManager = EmailManager(account: account, folderConfig: folderConfig)

        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 420, height: 550)
        popover.behavior = .transient
        popover.animates = true

        let contentView = ContentView(emailManager: emailManager)
        popover.contentViewController = NSHostingController(rootView: contentView)

        // Set up button
        if let button = statusItem.button {
            updateMenuBarIcon(unreadCount: 0, folderName: folderConfig.name)
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Observe unread count changes
        emailManager.$unreadCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.updateMenuBarIcon(unreadCount: count, folderName: folderConfig.name)
            }
            .store(in: &cancellables)

        // Start fetching only if account is properly configured
        if !account.host.isEmpty && !account.username.isEmpty {
            emailManager.startFetching()
        }
    }

    func updateMenuBarIcon(unreadCount: Int, folderName: String) {
        guard let button = statusItem.button else { return }

        if unreadCount > 0 {
            // Create attributed string with badge
            let iconAttachment = NSTextAttachment()
            iconAttachment.image = NSImage(systemSymbolName: "envelope.fill", accessibilityDescription: folderName)

            let iconString = NSMutableAttributedString(attachment: iconAttachment)

            let badgeText = unreadCount > 99 ? "99+" : "\(unreadCount)"
            let badgeString = NSAttributedString(string: " \(badgeText)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.systemRed
            ])

            iconString.append(badgeString)
            button.attributedTitle = iconString
            button.image = nil
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "envelope", accessibilityDescription: folderName)
        }

        // Update tooltip
        button.toolTip = folderName
    }

    @objc func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var folderMenuItems: [FolderMenuItem] = []
    var configObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Load and create menu items
        reloadConfigAndCreateMenuItems()

        // Listen for config changes
        configObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("RefreshEmails"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadConfigAndCreateMenuItems()
        }
    }

    func reloadConfigAndCreateMenuItems() {
        // Remove existing items
        for item in folderMenuItems {
            item.emailManager.stopFetching()
            NSStatusBar.system.removeStatusItem(item.statusItem)
        }
        folderMenuItems.removeAll()

        // Load config
        let config = AppConfig.load()

        // Create menu items for each account's folders
        for account in config.accounts {
            for folderConfig in account.folders where folderConfig.enabled {
                let menuItem = FolderMenuItem(account: account, folderConfig: folderConfig)
                folderMenuItems.append(menuItem)
            }
        }

        // If no folders configured, create a setup icon
        if folderMenuItems.isEmpty {
            let setupAccount = IMAPAccount(name: "Setup", host: "", username: "")
            let setupFolder = FolderConfig(name: "⚙️ Settings", folderPath: "")
            let setupItem = FolderMenuItem(account: setupAccount, folderConfig: setupFolder)
            folderMenuItems.append(setupItem)
        }
    }
}
