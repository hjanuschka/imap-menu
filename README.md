# IMAP Menu

A lightweight macOS menubar app for monitoring IMAP email folders.

## Features

- **Multiple Accounts**: Configure multiple IMAP accounts (Gmail, AWS WorkMail, etc.)
- **Multiple Folders**: Monitor multiple folders per account
- **One Icon Per Folder**: Each monitored folder gets its own menubar icon with unread count
- **Fast Loading**: Uses IMAP SEARCH to only fetch emails from the last 20 days
- **Auto-Refresh**: Automatically checks for new emails every 60 seconds
- **Mark as Read/Unread**: Click to mark emails as read or unread
- **Delete Emails**: Delete emails directly from the menubar
- **HTML Email Support**: View HTML emails with proper rendering

## Setup

1. Open the app - it will show a setup icon in the menubar
2. Click the menubar icon and go to Settings (or press `Cmd+,`)
3. Add an IMAP account:
   - Click the `+` button to add a new account
   - Enter your IMAP server details (host, port, username, password)
   - Click "Test Connection" to verify
   - Click "Browse Folders..." to see available folders
   - Select folders to monitor (each gets its own menubar icon)
4. Click "Save & Reload"

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

- **View Emails**: Click any folder's menubar icon to see emails
- **Read Email**: Click an email to expand and view the full message
- **Mark as Read**: Email is automatically marked as read after being expanded for 5 seconds
- **Mark as Unread**: Click the "Mark as Unread" button
- **Delete**: Click the delete button and confirm
- **Refresh**: Emails refresh automatically every 60 seconds, or click the refresh button

## Build from Source

```bash
swift build -c release
./build.sh
open IMAPMenu.app
```

## Install

```bash
cp -r IMAPMenu.app /Applications/
```

## License

MIT
