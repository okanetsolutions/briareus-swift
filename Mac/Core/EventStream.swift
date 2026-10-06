// A GET call's server-sent event stream (api_stream): the shared browser's frames and tabs, read as they arrive, on the
// same terms as every other call (the token, no cookies, no cache, no redirects), always over the network.
import Foundation

extension APIClient {
    /// Reads a GET call's event stream, handing each event to `emit` as it completes (on a queue of the stream's own,
    /// one event at a time), until the server ends it (returns), or it fails or the task is cancelled (throws, with
    /// `.cancelled` for the latter).
    func stream(_ name: String, _ arguments: JSON = [:], emit: @escaping @Sendable (_ event: String, _ data: String) -> Void) async throws {
        guard let route = APIRoute.named(name), route.method == "GET" else { throw APIError(.http, status: 400, message: "Unknown call") }
        var (path, rest) = try APIClient.resolve(route, arguments)
        var sep = "?"
        for key in rest.keys.sorted() {
            guard let value = APIClient.urlValue(rest[key]!, inPath: false) else { continue }
            path += "\(sep)\(APIClient.encode(key))=\(value)"
            sep = "&"
        }
        guard let url = URL(string: address.baseURL + path) else { throw APIError(.invalidAddress) }
        // The server pings every 25 seconds: a minute of silence is a connection that went away.
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        request.httpShouldHandleCookies = false
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        try await EventStreamReader(emit: emit).run(request)
    }
}

/// One stream's connection: its bytes go through an SSEParser as they come, and the outcome resumes the caller.
private final class EventStreamReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let emit: @Sendable (String, String) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var cancelled = false
    // On the delegate queue only.
    private var parser = SSEParser()
    private var status = 0
    private var contentType: String?
    private var retryAfter: String?
    private var refusal = Data()

    init(emit: @escaping @Sendable (String, String) -> Void) { self.emit = emit }

    func run(_ request: URLRequest) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled { lock.unlock(); c.resume(throwing: APIError(.cancelled)); return }
                continuation = c
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil
                config.httpShouldSetCookies = false
                config.urlCache = nil
                config.urlCredentialStorage = nil
                config.tlsMinimumSupportedProtocolVersion = .TLSv12
                config.timeoutIntervalForRequest = 60
                config.timeoutIntervalForResource = 7 * 86400
                config.httpAdditionalHeaders = ["User-Agent": "Briareus-Mac/1.0"]
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                let t = session.dataTask(with: request)
                task = t
                lock.unlock()
                t.resume()
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            let t = task
            lock.unlock()
            t?.cancel()
        }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            status = http.statusCode
            contentType = http.value(forHTTPHeaderField: "Content-Type")
            retryAfter = http.value(forHTTPHeaderField: "Retry-After")
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if status >= 200 && status < 300 {
            let emit = self.emit
            parser.feed(data) { emit($0, $1) }
        } else if refusal.count < 4096 {
            // The refusal's own words, as a JSON body says them.
            refusal.append(data.prefix(4096 - refusal.count))
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        if let error = error as? URLError {
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            finish(error.code == .cancelled || wasCancelled ? APIError(.cancelled) : APIError(.network, message: URLSessionTransport.text(error)))
            return
        }
        if let error { finish(APIError(.network, message: error.localizedDescription)); return }
        if status >= 300 && status < 400 { finish(APIError(.redirected, status: status)); return }
        if status < 200 || status >= 300 {
            let json = contentType?.lowercased().contains("json") == true ? JSON.parse(refusal) : nil
            finish(APIError(.http, status: status, message: json?["error"].nonEmpty ?? APIError.statusText(status),
                            retryAfter: retryAfterSeconds(retryAfter)))
            return
        }
        finish(nil)
    }
}
