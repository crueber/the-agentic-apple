import Foundation

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var headers: [String: String]
    public init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }
    public var json: [String: Any]? { Sanitize.jsonObject(body) }
}

public enum HTTPError: Error, Sendable, CustomStringConvertible {
    case transport(String)
    case tooLarge
    case invalidURL

    public var description: String {
        switch self {
        case .transport(let m): return m
        case .tooLarge: return "response too large"
        case .invalidURL: return "invalid URL"
        }
    }
}

/// Injectable HTTP: the real one uses URLSession; tests pass a closure.
public struct HTTPClient: Sendable {
    public var get: @Sendable (_ url: String, _ headers: [String: String]) async throws -> HTTPResponse

    public init(get: @escaping @Sendable (_ url: String, _ headers: [String: String]) async throws -> HTTPResponse) {
        self.get = get
    }

    public static let maxBody = 1024 * 1024
    public static let timeout: TimeInterval = 15

    /// HTTPS only, no redirects followed, no cookies, no cache, 1 MB cap, 15 s timeout.
    public static let live = HTTPClient { urlString, headers in
        guard let url = URL(string: urlString), url.scheme == "https" else { throw HTTPError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.urlCache = nil
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard data.count <= maxBody else { throw HTTPError.tooLarge }
            let http = response as? HTTPURLResponse
            var h: [String: String] = [:]
            for (k, v) in http?.allHeaderFields ?? [:] { h[String(describing: k).lowercased()] = String(describing: v) }
            return HTTPResponse(status: http?.statusCode ?? 0, body: data, headers: h)
        } catch let e as HTTPError {
            throw e
        } catch {
            throw HTTPError.transport((error as NSError).localizedDescription)
        }
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

extension CollectorContext {
    public var httpClient: HTTPClient { http ?? .live }

    /// Find a tool: explicit override wins, else search PATH.
    public func resolveCommand(_ override: String, default name: String) -> String? {
        let o = override.trimmingCharacters(in: .whitespaces)
        if !o.isEmpty { return Shell.which(o, searchPath: searchPath) }
        return Shell.which(name, searchPath: searchPath)
    }

    /// Environment for child processes: the caller's, with PATH set to our search path and HOME to `home`.
    public var childEnvironment: [String: String] {
        var env = environment
        env["PATH"] = searchPath.joined(separator: ":")
        env["HOME"] = home.path
        return env
    }
}
