import Foundation

// Set to false to disable verbose logging in release builds
#if DEBUG
let kDebugLoggingEnabled = true
#else
let kDebugLoggingEnabled = false
#endif

/// Debug logging that can be disabled in production
/// Uses @autoclosure to avoid string interpolation cost when disabled
func debugLog(_ message: @autoclosure () -> String) {
    if kDebugLoggingEnabled {
        print(message())
    }
}
