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

/// Injectable HTTP: the real one uses URLSession; tests pass closures.
public struct HTTPClient: Sendable {
    public typealias Get = @Sendable (_ url: String, _ headers: [String: String]) async throws -> HTTPResponse
    public typealias Post = @Sendable (_ url: String, _ headers: [String: String], _ body: Data) async throws -> HTTPResponse

    public var get: Get
    /// JSON POST (OpenRouter analytics). nil = this client cannot POST.
    public var post: Post?

    public init(get: @escaping Get, post: Post? = nil) {
        self.get = get
        self.post = post
    }

    public static let maxBody = 1024 * 1024
    /// Request bodies are small JSON documents.
    public static let maxRequestBody = 16 * 1024
    public static let timeout: TimeInterval = 15

    /// HTTPS only, no redirects followed, no cookies, no cache, 1 MB cap, 15 s timeout.
    public static let live = HTTPClient(
        get: { url, headers in try await perform("GET", url, headers, body: nil) },
        post: { url, headers, body in try await perform("POST", url, headers, body: body) })

    static func perform(_ method: String, _ urlString: String, _ headers: [String: String], body: Data?) async throws -> HTTPResponse {
        guard let url = URL(string: urlString), url.scheme == "https" else { throw HTTPError.invalidURL }
        if let body, body.count > maxRequestBody { throw HTTPError.tooLarge }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let body { request.httpBody = body }
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
