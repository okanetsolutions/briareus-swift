// Shared write gating and recovery for personal connections, sharing and SSH monitoring.
import Foundation

enum SettingsWritePolicy {
    static func allows(supported: Bool, busy: Bool, uncertain: Bool) -> Bool {
        supported && !busy && !uncertain
    }
    /// Only a definite refusal permits another write without first checking the saved state.
    static func isUncertain(_ error: Error) -> Bool {
        !((error as? APIError)?.isRefusal ?? false)
    }
}
