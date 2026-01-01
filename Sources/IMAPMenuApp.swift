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
    
    deinit {
        print("[FolderMenuItem] DEINIT for \(emailManager.folderConfig.name)")
        cancellables.removeAll()
        emailManager.stopFetching()
    }

    init(account: IMAPAccount, folderConfig: FolderConfig) {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true

        // Create email manager
        emailManager = EmailManager(account: account, folderConfig: folderConfig)

        // Create popover
        popover = NSPopover()
        popover.contentSize = folderConfig.popoverWidth.size
        popover.behavior = .transient
        popover.animates = true

        print("    🪟 Popover created with size: \(folderConfig.popoverWidth.size)")

        let contentView = ContentView(emailManager: emailManager)
            .frame(width: folderConfig.popoverWidth.size.width,
                   height: folderConfig.popoverWidth.size.height)
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
                guard let self = self else { return }
                print("📢 [\(folderConfig.name)] unreadCount changed to \(count), icon='\(self.emailManager.folderConfig.icon)'")
                self.updateMenuBarIcon(unreadCount: count, folderName: folderConfig.name)
            }
            .store(in: &cancellables)

        // Start fetching only if account is properly configured
        if !account.host.isEmpty && !account.username.isEmpty {
            emailManager.startFetching()
        }
    }

    func updateMenuBarIcon(unreadCount: Int, folderName: String) {
        guard let button = statusItem.button else { return }

        // Get custom icon from folder config
        let iconName = emailManager.folderConfig.icon
        let filledIconName = iconName.contains(".fill") ? iconName : "\(iconName).fill"
        let iconColor = emailManager.folderConfig.nsColor

        // Debug: log icon changes
        if button.toolTip != folderName || (button.image == nil && unreadCount == 0) {
            print("📊 [\(folderName)] updateMenuBarIcon: icon='\(iconName)', unread=\(unreadCount), iconExists=\(NSImage(systemSymbolName: iconName, accessibilityDescription: nil) != nil)")
        }

        // Determine which icon to use
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let baseIconName = unreadCount > 0 ? filledIconName : iconName
        let iconImage = NSImage(systemSymbolName: baseIconName, accessibilityDescription: folderName)
            ?? NSImage(systemSymbolName: iconName, accessibilityDescription: folderName)
            ?? NSImage(systemSymbolName: "envelope", accessibilityDescription: folderName)

        // Apply color to icon
        let coloredIcon = iconImage?.withSymbolConfiguration(config)
        let finalImage: NSImage?
        if !emailManager.folderConfig.iconColor.isEmpty {
            finalImage = coloredIcon?.image(tintedWith: iconColor)
        } else {
            finalImage = coloredIcon
        }

        // Create icon attachment
        let iconAttachment = NSTextAttachment()
        iconAttachment.image = finalImage

        let iconString = NSMutableAttributedString(attachment: iconAttachment)

        // Add badge number (always reserve space for consistent alignment)
        if unreadCount > 0 {
            let badgeText = unreadCount > 99 ? "99+" : "\(unreadCount)"
            let badgeString = NSAttributedString(string: " \(badgeText)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.systemRed
            ])
            iconString.append(badgeString)
        } else {
            // Reserve space but make it invisible for consistent alignment
            let spacer = NSAttributedString(string: "  ", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            ])
            iconString.append(spacer)
        }

        button.attributedTitle = iconString
        button.image = nil

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
        print("🔄 reloadConfigAndCreateMenuItems called")

        // Stop and remove existing items - ensure complete cleanup
        for item in folderMenuItems {
            item.cancellables.removeAll()  // Cancel all Combine subscriptions
            item.emailManager.stopFetching()
            item.popover.close()
            NSStatusBar.system.removeStatusItem(item.statusItem)
        }
        folderMenuItems.removeAll()
        
        // Clear cache when reloading to prevent stale data accumulation
        // (individual folders will repopulate on next fetch)
        print("🧹 Clearing email cache on reload")

        // Load config
        let config = AppConfig.load()

        // Create menu items for each account's folders
        for account in config.accounts {
            for folderConfig in account.folders where folderConfig.enabled {
                print("  📐 Creating menuItem for '\(folderConfig.name)' with width: \(folderConfig.popoverWidth.rawValue) (\(folderConfig.popoverWidth.size))")
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

        print("✅ Created \(folderMenuItems.count) menu items")
    }
}
extension NSImage {
    func image(tintedWith color: NSColor) -> NSImage {
        guard self.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil else {
            return self
        }

        return NSImage(size: size, flipped: false) { bounds in
            color.setFill()
            bounds.fill()

            let imageRect = NSRect(origin: .zero, size: self.size)
            self.draw(in: imageRect, from: imageRect, operation: .destinationIn, fraction: 1.0)

            return true
        }
    }
}
