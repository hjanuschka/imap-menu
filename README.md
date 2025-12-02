# IMAP Menu

A lightweight macOS menubar app for monitoring IMAP email folders with instant notifications and quick actions.

## Features

- 🔔 **Real-time notifications** - Unread count badges in menubar
- 📬 **Multiple accounts & folders** - Monitor multiple IMAP accounts and folders simultaneously
- 🎨 **Customizable icons** - Choose from 500+ SF Symbols with custom colors
- ⚡ **Instant actions** - Mark read/unread, delete emails with optimistic UI updates
- 🔍 **Email filtering** - Filter by sender and/or subject
- 📐 **Adjustable size** - Small, medium, or large popover sizes
- 🔐 **Secure** - Passwords stored in macOS Keychain
- 🚀 **Fast** - Optimized IMAP queries, ~2 second load times
- 🔄 **Auto-refresh** - Configurable 60-second refresh interval
- 📧 **HTML emails** - Full HTML rendering with WKWebView

## Quick Start

1. **Launch** the app - a ⚙️ icon appears in menubar
2. **Click** the icon → Settings
3. **Add Account**:
   - Name, host, port, username, password
   - Test connection
   - Browse folders
4. **Configure Folders**:
   - Display name
   - Choose icon (500+ available)
   - Pick color
   - Set filters (optional)
   - Select popover width
5. **Save & Refresh** - folder icons appear in menubar!

## Example Configuration

### AWS WorkMail
- **Host**: `imap.mail.{region}.awsapps.com` (e.g., `imap.mail.us-east-1.awsapps.com`)
- **Port**: `993`
- **SSL**: Enabled
- **Username**: Your email address
- **Password**: Your password

### Gmail
- **Host**: `imap.gmail.com`
- **Port**: `993`
- **SSL**: Enabled
- **Username**: Your Gmail address
- **Password**: App-specific password (not your regular password)

## Usage

- **View Emails**: Click any folder's menubar icon to see emails in a popover
- **Read Email**: Click an email to expand inline and view the full HTML message
- **Auto-mark as Read**: Email is automatically marked as read after being expanded for 5 seconds
- **Quick Actions**: Use the action buttons on each email to:
  - Toggle read/unread status (instant feedback)
  - Delete email (instant feedback)
- **Refresh**: Emails refresh automatically every 60 seconds, or click the refresh button
- **Context Menu**: Right-click any email for additional options

## Advanced Features

### Filtering
Each folder can have filters applied:
- **Sender Filter**: Only show emails from specific senders (comma-separated)
- **Subject Filter**: Only show emails with specific subject keywords

### Custom Icons & Colors
- Choose from 500+ SF Symbols (e.g., `envelope`, `network`, `bag`, `flag`)
- Customize icon color with 12 presets or enter custom hex codes
- Icons automatically show filled variant when unread emails exist

### Performance
- Optimized IMAP queries fetch only headers initially
- Full email body loads on-demand when expanded
- Typical load time: ~2 seconds for 50 emails
- Background auto-refresh every 60 seconds
- Optimistic UI updates for instant feedback

### Security
- Passwords stored securely in macOS Keychain
- SSL/TLS encryption for all IMAP connections
- No credentials stored in plain text

## Build from Source

### Requirements
- macOS 12.0 or later
- Xcode 14.0 or later
- Swift 5.7 or later

### Building
```bash
# Debug build
swift build

# Release build
swift build -c release

# Run from build directory
.build/release/IMAPMenu
```

### Creating App Bundle
```bash
# Build and package as .app
./build.sh

# Open the app
open IMAPMenu.app

# Install to Applications
cp -r IMAPMenu.app /Applications/
```

## Building Universal Binary

For distribution, create a universal binary that runs on both Intel and Apple Silicon:

```bash
./release.sh
```

This creates `IMAPMenu-universal.zip` with a fat binary supporting both architectures.

## Troubleshooting

### App doesn't appear in menubar
- Check Console.app for error messages
- Verify IMAP settings are correct
- Test connection in Settings

### Gmail "Authentication failed"
- Enable IMAP in Gmail settings
- Generate an App Password (don't use your regular password)
- Use the App Password in IMAP Menu

### AWS WorkMail connection issues
- Ensure you're using the correct regional endpoint
- Format: `imap.mail.{region}.awsapps.com`
- Verify port 993 and SSL are enabled

### Icons not updating
- Click the refresh button manually
- Check connection status (green/red dot in footer)
- Restart the app

### High CPU usage
- Increase auto-refresh interval in code (default 60s)
- Reduce number of monitored folders
- Check for IMAP server issues

## Configuration Backup

Settings are stored in macOS UserDefaults:

```bash
# Export config
defaults read com.imapmenu.app AppConfig > config.json

# Import config
defaults write com.imapmenu.app AppConfig "$(cat config.json)"
```

**Note**: This doesn't include passwords (stored in Keychain).

## License

MIT
