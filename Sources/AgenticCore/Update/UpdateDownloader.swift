import Darwin
import Foundation

/// Downloads a release asset to a file. Unlike `HTTPClient` (no redirects,
/// 1 MB), release assets redirect from github.com to
/// release-assets.githubusercontent.com and are megabytes long, so:
/// - HTTPS only; the first URL and every redirect must pass
///   `UpdatePolicy.isAllowedDownloadURL` (github.com, *.githubusercontent.com),
///   at most `maxRedirects` hops;
/// - streamed straight to `destination`, created exclusively (O_EXCL,
///   O_NOFOLLOW, 0600) — the caller passes a path inside a fresh 0700 directory;
/// - aborted as soon as more than `maxBytes` arrive; when `expectedSize` is
///   given the final size must equal it;
/// - no cookies, no cache, no credentials; `requestTimeout` without progress
///   or `resourceTimeout` in total ends it.
///
/// `protocolClasses` exists only so the self-test can drive the real session
/// delegate offline with a `URLProtocol` stub.
public final class UpdateDownloader: @unchecked Sendable {
    public static let maxRedirects = 5
    public let requestTimeout: TimeInterval
    public let resourceTimeout: TimeInterval
    private let protocolClasses: [AnyClass]

    public init(requestTimeout: TimeInterval = 30, resourceTimeout: TimeInterval = 600, protocolClasses: [AnyClass] = []) {
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.protocolClasses = protocolClasses
    }

    public func download(_ url: URL, to destination: URL, maxBytes: Int, expectedSize: Int?) async throws {
        guard UpdatePolicy.isAllowedDownloadURL(url) else {
            throw UpdateError.download("Refused to download from outside GitHub (HTTPS only)")
        }
        let cap = min(maxBytes, expectedSize.map { $0 > 0 ? $0 : maxBytes } ?? maxBytes)
        let fd = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw UpdateError.download("Could not create the download file") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if !protocolClasses.isEmpty { config.protocolClasses = protocolClasses }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(UpdateFeed.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let written: Int = try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(handle: handle, cap: cap, continuation: continuation)
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            session.dataTask(with: request).resume()
            session.finishTasksAndInvalidate()
        }
        if let expectedSize, expectedSize > 0, written != expectedSize {
            throw UpdateError.download("The download was \(written) bytes, expected \(expectedSize)")
        }
        if written == 0 { throw UpdateError.download("The download was empty") }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let cap: Int
    private var continuation: CheckedContinuation<Int, Error>?
    private var written = 0
    private var redirects = 0
    private var failure: UpdateError?

    init(handle: FileHandle, cap: Int, continuation: CheckedContinuation<Int, Error>) {
        self.handle = handle
        self.cap = cap
        self.continuation = continuation
    }

    private func fail(_ error: UpdateError, _ task: URLSessionTask) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        redirects += 1
        let count = redirects
        lock.unlock()
        guard let url = request.url, UpdatePolicy.isAllowedDownloadURL(url) else {
            fail(.download("Refused a redirect away from GitHub"), task)
            completionHandler(nil)
            return
        }
        guard count <= UpdateDownloader.maxRedirects else {
            fail(.download("Too many redirects"), task)
            completionHandler(nil)
            return
        }
        var next = request
        next.httpShouldHandleCookies = false
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = http.url, UpdatePolicy.isAllowedDownloadURL(url) else {
            fail(.download("Unexpected response"), dataTask)
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 200 else {
            fail(.download("GitHub answered \(http.statusCode) for the download"), dataTask)
            completionHandler(.cancel)
            return
        }
        if http.expectedContentLength > 0, http.expectedContentLength > Int64(cap) {
            fail(.download("The download is larger than expected"), dataTask)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if failure != nil { lock.unlock(); return }
        if written + data.count > cap {
            lock.unlock()
            fail(.download("The download is larger than expected"), dataTask)
            return
        }
        written += data.count
        lock.unlock()
        do {
            try handle.write(contentsOf: data)
        } catch {
            fail(.download("Could not write the download"), dataTask)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle.synchronize()
        try? handle.close()
        lock.lock()
        let c = continuation
        continuation = nil
        let failure = self.failure
        let written = self.written
        lock.unlock()
        if let failure {
            c?.resume(throwing: failure)
        } else if let error {
            let ns = error as NSError
            let message = ns.code == NSURLErrorTimedOut ? "The download timed out" : "The download failed"
            c?.resume(throwing: UpdateError.download(message))
        } else if let http = task.response as? HTTPURLResponse, http.statusCode != 200 {
            c?.resume(throwing: UpdateError.download("GitHub answered \(http.statusCode) for the download"))
        } else {
            c?.resume(returning: written)
        }
    }
}
