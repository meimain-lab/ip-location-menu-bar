import Foundation

enum IPAPIError: LocalizedError {
    case http(Int)
    case api(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(let code):
            return "服务器返回 HTTP \(code)"
        case .api(let reason) where reason == "RateLimited":
            return "请求过于频繁，ipapi 暂时限流"
        case .api(let reason):
            return "ipapi 返回错误：\(reason)"
        case .invalidResponse:
            return "无法解析 ipapi 的响应"
        }
    }
}

extension Error {
    /// True for errors caused by cancelling an in-flight request, which should not be shown.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        return (self as? URLError)?.code == .cancelled
    }

    var isRateLimited: Bool {
        switch self as? IPAPIError {
        case .api(let reason): return reason == "RateLimited"
        case .http(let code): return code == 429
        default: return false
        }
    }
}

struct IPAPIClient {
    /// Set IPAPI_LOOKUP_IP=<ip> to look up another IP instead, e.g. to test the mismatch alert.
    private static let endpoint: URL = {
        if let ip = ProcessInfo.processInfo.environment["IPAPI_LOOKUP_IP"].nonEmpty,
           let url = URL(string: "https://ipapi.co/\(ip)/json/") {
            return url
        }
        return URL(string: "https://ipapi.co/json/")!
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        // Right after a reconnect DNS/routes are often not ready yet; wait instead of failing at once.
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    func fetch() async throws -> IPInfo {
        var request = URLRequest(url: Self.endpoint)
        // ipapi.co rate-limits generic user agents (e.g. curl's default) far more aggressively.
        request.setValue("IPLocationMenuBar/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        // ipapi reports errors in the body, sometimes with HTTP 200 and sometimes with 429.
        if let body = try? decoder.decode(IPAPIErrorBody.self, from: data), body.error == true {
            throw IPAPIError.api(body.reason ?? "未知原因")
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw IPAPIError.http(http.statusCode)
        }
        guard let info = try? decoder.decode(IPInfo.self, from: data) else {
            throw IPAPIError.invalidResponse
        }
        return info
    }
}
