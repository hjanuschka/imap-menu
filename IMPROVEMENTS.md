# IMAPMenu Improvements

## Completed ✅

### Memory & Performance
- [x] Fixed memory leak from duplicate notification listener (was causing 2x fetches)
- [x] Added global cache limit (2000 emails) with LRU eviction
- [x] Reduced per-folder cache from 1000 to 500 emails
- [x] Stop fetching at 99+ unread (no point showing more)
- [x] Early cancellation in parallel fetch when hitting limits
- [x] Reduced response buffer from 10MB to 5MB
- [x] Connection keep-alive (NOOP every 4 minutes)
- [x] Adaptive polling (60s → 180s when inbox is quiet)
- [x] Disk cache persistence for faster startup

### Features
- [x] macOS notifications for new emails
- [x] Search/filter emails locally
- [x] Dark mode support in email WebView
- [x] Right-click context menu on menu bar icon
- [x] "Open in Mail.app" button
- [x] Show last sync time in footer
- [x] App version in Settings

### Code Quality
- [x] Debug logging toggle (disabled in release)
- [x] Centralized debugLog() function
- [x] Proper cleanup in deinit methods

## Future Ideas 💡

### High Priority
- [ ] IMAP IDLE for real-time push notifications (no polling needed)
- [ ] Keyboard navigation (j/k to move, r to reply, d to delete)
- [ ] Auto-reconnect with exponential backoff on connection failure

### Medium Priority
- [ ] Unread badge on app icon in Dock (when visible)
- [ ] Quick compose from menu bar
- [ ] Swipe gestures for mark read/delete
- [ ] Email threading/conversation view
- [ ] Attachment preview/download

### Low Priority
- [ ] Unit tests for MIME parsing and filters
- [ ] Localization support
- [ ] Custom notification sounds
- [ ] Multiple account support improvements (unified inbox view)
- [ ] Export emails to mbox/eml format

## Architecture Notes

### Connection Management
- Each folder has its own dedicated IMAP connection
- Connections are reused for delta fetches
- Keep-alive NOOP prevents server timeout
- Parallel fetch creates temporary connections for speed

### Caching Strategy
- In-memory cache with 500 emails per folder limit
- Global limit of 2000 emails across all folders
- LRU eviction when limits exceeded
- Disk persistence to ~/Library/Application Support/IMAPMenu/
- Cache expires after 1 hour on disk

### Notification Flow
1. Emails fetched from server
2. Filtered by user rules
3. Compared against previously notified UIDs
4. New unread emails trigger notification
5. UIDs tracked to prevent duplicate notifications
