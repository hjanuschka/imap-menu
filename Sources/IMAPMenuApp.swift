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

        // Create popover with modern appearance
        popover = NSPopover()
        popover.contentSize = folderConfig.popoverWidth.size
        popover.behavior = .transient
        popover.animates = true

        print("    🪟 Popover created with size: \(folderConfig.popoverWidth.size)")

        let contentView = ContentView(emailManager: emailManager)
            .frame(width: folderConfig.popoverWidth.size.width,
                   height: folderConfig.popoverWidth.size.height)
        
        let hostingController = NSHostingController(rootView: contentView)
        // Remove default background to let vibrancy show through
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = .clear
        popover.contentViewController = hostingController

        // Set up button
        if let button = statusItem.button {
            updateMenuBarIcon(unreadCount: 0, folderName: folderConfig.name)
            button.action = #selector(togglePopover)
            button.target = self
            
            // Enable right-click handling
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

        // Get icon configuration
        let folderConfig = emailManager.folderConfig
        let iconColor = folderConfig.nsColor

        // Get or create the icon based on type
        let iconImage: NSImage? = getMenuBarIcon(for: folderConfig, hasUnread: unreadCount > 0)
        
        // Apply color only for SF Symbols (not for custom URL/file icons)
        let finalImage: NSImage?
        if folderConfig.iconType == .sfSymbol && !folderConfig.iconColor.isEmpty, let image = iconImage {
            finalImage = image.image(tintedWith: iconColor)
        } else {
            finalImage = iconImage
        }

        // Create icon attachment with proper bounds for menu bar
        let iconAttachment = NSTextAttachment()
        iconAttachment.image = finalImage
        
        // Set bounds to vertically center the icon in the menu bar
        if let image = finalImage {
            // yOffset adjusts for text baseline - negative moves icon up
            let yOffset: CGFloat = -2
            iconAttachment.bounds = CGRect(x: 0, y: yOffset, width: image.size.width, height: image.size.height)
        }

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
    
    // Cache for downloaded images (cleared on app restart)
    private static var imageCache: [String: NSImage] = [:]
    
    // Clear cache for a specific icon (useful when icon changes)
    static func clearIconCache(for key: String) {
        imageCache.removeValue(forKey: key)
    }
    
    private func getMenuBarIcon(for folderConfig: FolderConfig, hasUnread: Bool) -> NSImage? {
        let iconSize = NSSize(width: 18, height: 18)
        
        switch folderConfig.iconType {
        case .sfSymbol:
            // SF Symbol (current behavior)
            let iconName = folderConfig.icon
            let filledIconName = iconName.contains(".fill") ? iconName : "\(iconName).fill"
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            let baseIconName = hasUnread ? filledIconName : iconName
            
            let image = NSImage(systemSymbolName: baseIconName, accessibilityDescription: folderConfig.name)
                ?? NSImage(systemSymbolName: iconName, accessibilityDescription: folderConfig.name)
                ?? NSImage(systemSymbolName: "envelope", accessibilityDescription: folderConfig.name)
            
            return image?.withSymbolConfiguration(config)
            
        case .url:
            // URL to image (download and cache)
            let urlString = folderConfig.icon
            
            // Check cache first
            if let cached = FolderMenuItem.imageCache[urlString] {
                return resizeImageForMenuBar(cached, size: iconSize)
            }
            
            // Download asynchronously
            if let url = URL(string: urlString) {
                downloadImage(from: url) { image in
                    if let image = image {
                        FolderMenuItem.imageCache[urlString] = image
                        // Trigger UI update
                        DispatchQueue.main.async {
                            self.updateMenuBarIcon(unreadCount: self.emailManager.unreadCount, folderName: folderConfig.name)
                        }
                    }
                }
            }
            
            // Return fallback while downloading
            return NSImage(systemSymbolName: "envelope", accessibilityDescription: folderConfig.name)
            
        case .file:
            // Local file path
            let filePath = folderConfig.icon
            
            // Check cache first
            if let cached = FolderMenuItem.imageCache[filePath] {
                return resizeImageForMenuBar(cached, size: iconSize)
            }
            
            // Expand ~ and load file
            let expandedPath = NSString(string: filePath).expandingTildeInPath
            if let image = NSImage(contentsOfFile: expandedPath) {
                FolderMenuItem.imageCache[filePath] = image
                return resizeImageForMenuBar(image, size: iconSize)
            }
            
            // Return fallback if file not found
            return NSImage(systemSymbolName: "envelope", accessibilityDescription: folderConfig.name)
        }
    }
    
    private func downloadImage(from url: URL, completion: @escaping (NSImage?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil, let image = NSImage(data: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async { completion(image) }
        }.resume()
    }
    
    private func resizeImageForMenuBar(_ image: NSImage, size: NSSize) -> NSImage {
        let resized = NSImage(size: size)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        resized.unlockFocus()
        // Don't set isTemplate for custom images - preserve original colors
        resized.isTemplate = false
        return resized
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        guard let event = NSApp.currentEvent else {
            showPopover()
            return
        }
        
        if event.type == .rightMouseUp {
            // Show context menu on right-click
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Refresh \(emailManager.folderConfig.name)", action: #selector(refreshEmails), keyEquivalent: ""))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Mark All as Read", action: #selector(markAllAsRead), keyEquivalent: ""))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ""))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit IMAPMenu", action: #selector(quitApp), keyEquivalent: ""))
            
            for item in menu.items {
                item.target = self
            }
            
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            showPopover()
        }
    }
    
    private func showPopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    
    @objc func refreshEmails() {
        emailManager.refresh()
    }
    
    @objc func markAllAsRead() {
        for email in emailManager.emails where !email.isRead {
            emailManager.markAsRead(email)
        }
    }
    
    @objc func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
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
