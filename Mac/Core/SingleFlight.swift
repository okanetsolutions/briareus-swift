// Identical reads at once share one request: several screens (an iPad's windows, a board and the issue over it) poll
// the same feed, and on a weak link each extra copy of a large answer slows down the one that matters.
import Foundation

final class SingleFlight<Value: Sendable>: @unchecked Sendable {
    private final class Flight {
        var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]
        var task: Task<Void, Never>?
    }
    private let lock = NSLock()
    private var flights: [String: Flight] = [:]

    init() {}

    /// How many distinct reads are under way, and how many callers wait on them, for the tests.
    var inFlight: Int { lock.lock(); defer { lock.unlock() }; return flights.count }
    var waiting: Int { lock.lock(); defer { lock.unlock() }; return flights.values.reduce(0) { $0 + $1.waiters.count } }

    /// `work`'s answer, from the read already under way for `key` if there is one. A caller cancelled meanwhile gets
    /// `APIError(.cancelled)` at once; the read itself is cancelled only once every caller has gone.
    func run(_ key: String, _ work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Value, Error>) in
                lock.lock()
                if Task.isCancelled { lock.unlock(); c.resume(throwing: APIError(.cancelled)); return }
                if let flight = flights[key] {
                    flight.waiters[id] = c
                    lock.unlock()
                    return
                }
                let flight = Flight()
                flight.waiters[id] = c
                flights[key] = flight
                flight.task = Task { [weak self] in
                    let result: Result<Value, Error>
                    do { result = .success(try await work()) } catch { result = .failure(error) }
                    self?.land(key, flight, result)
                }
                lock.unlock()
            }
        } onCancel: {
            leave(key, id)
        }
    }

    private func land(_ key: String, _ flight: Flight, _ result: Result<Value, Error>) {
        lock.lock()
        if flights[key] === flight { flights[key] = nil }
        let waiters = flight.waiters
        flight.waiters = [:]
        lock.unlock()
        for c in waiters.values { c.resume(with: result) }
    }

    private func leave(_ key: String, _ id: UUID) {
        lock.lock()
        guard let flight = flights[key], let c = flight.waiters.removeValue(forKey: id) else { lock.unlock(); return }
        let abandoned = flight.waiters.isEmpty
        if abandoned { flights[key] = nil }
        let task = flight.task
        lock.unlock()
        c.resume(throwing: APIError(.cancelled))
        if abandoned { task?.cancel() }
    }
}
