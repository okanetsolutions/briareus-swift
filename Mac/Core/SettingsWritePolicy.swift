// Shared write gating and recovery for personal connections, sharing, SSH monitoring and code review edits.
import Foundation

enum SettingsWritePolicy {
    static func allows(supported: Bool, busy: Bool, uncertain: Bool) -> Bool {
        supported && !busy && !uncertain
    }
    /// Only a definite refusal permits another write without first checking the saved state.
    static func isUncertain(_ error: Error) -> Bool {
        !((error as? APIError)?.isRefusal ?? false)
    }
    /// A failed write's message: a refusal as said, anything else noting that the write may still have been saved.
    static func failureText(_ message: String, _ error: Error) -> String {
        isUncertain(error) ? "\(message) It may still have been saved; refresh before trying again." : message
    }
}
