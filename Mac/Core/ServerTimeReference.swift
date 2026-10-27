// An HTTP Date header anchored to elapsed time, so server timestamps never depend on the device's wall clock.
import Foundation

struct ServerTimeReference: Sendable {
    private let date: Date
    private let receivedAt: ContinuousClock.Instant

    init?(_ header: String?, at receivedAt: ContinuousClock.Instant = .now) {
        guard let header else { return nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "GMT")
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = format.date(from: header) else { return nil }
        self.date = date
        self.receivedAt = receivedAt
    }

    func now(at instant: ContinuousClock.Instant = .now) -> Date {
        let elapsed = receivedAt.duration(to: instant).components
        return date.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }
}
