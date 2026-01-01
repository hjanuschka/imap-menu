# Potential Improvements for IMAPMenu

## High Priority (Performance & Reliability)

### 1. Add Debug Logging Toggle
Currently there are 71 print statements. Add a debug mode toggle to disable verbose logging in production.

### 2. Connection Pooling / Keep-Alive
The dedicated connection per folder is good, but connections can go stale. Add periodic NOOP commands to keep connections alive and avoid reconnection overhead.

### 3. Smarter Delta Fetch
Currently delta fetch only works if `highestCachedUID > 0`. Consider:
- Persisting `highestUID` to disk so delta fetch works across app restarts
- Using IMAP IDLE for real-time push notifications instead of polling

### 4. Reduce Polling Frequency When Idle
If no new emails in last N fetches, gradually increase the refresh interval (e.g., 60s → 120s → 300s).

### 5. Background Fetch Optimization
Use `URLSession` background tasks or proper background app refresh on macOS for better battery life.

## Medium Priority (UX Improvements)

### 6. Keyboard Navigation
Add keyboard shortcuts for:
- `j/k` - Move up/down in email list
- `r` - Reply
- `a` - Reply all
- `d` - Delete
- `u` - Mark unread
- `Space` - Toggle email detail view

### 7. Search Functionality
Add local search across cached emails (subject, sender, body).

### 8. Notification Support
Show macOS notifications for new unread emails.

### 9. Quick Actions from Menu Bar
Right-click on menu bar icon could show:
- Recent emails
- Quick compose
- Mark all as read

### 10. Dark Mode Support
The email body WebView has hardcoded white background. Respect system appearance.

## Low Priority (Code Quality)

### 11. Extract IMAP Protocol Parser
The IMAP parsing code in `IMAPConnection` is mixed with connection logic. Consider separating:
- `IMAPProtocol` - Parsing IMAP responses
- `IMAPConnection` - Network handling
- `IMAPSession` - High-level operations

### 12. Unit Tests
Add tests for:
- MIME parsing
- Email filtering
- Cache eviction logic

### 13. Error Recovery
Add automatic reconnection with exponential backoff when connection fails.

### 14. Memory Profiling
Add Instruments integration points to track memory usage over time.

### 15. Localization
Extract user-facing strings for localization support.

## Quick Wins (Can implement now)

### A. Reduce unnecessary print statements in production
### B. Add app version/build info to settings
### C. Show last successful sync time in footer
### D. Add "Open in Mail.app" button for emails
### E. Cache email body content to avoid re-fetching
