import Foundation
import OSLog

private let log = Logger(subsystem: "local.ip-location-menu-bar", category: "provider")

enum IPAPIError: LocalizedError {
    case http(Int)
    case api(String)
    case invalidResponse
    /// Every source tried failed; holds "source: reason" for each.
    case allFailed([String])
    /// Simulated with IPAPI_FAIL_PROVIDERS for testing.
    case simulated

    var errorDescription: String? {
        switch self {
        case .http(429):
            return "请求过于频繁，暂时限流"
        case .http(let code):
            return "服务器返回 HTTP \(code)"
        case .api(let reason) where reason == "RateLimited":
            return "请求过于频繁，暂时限流"
        case .api(let reason):
            return "返回错误：\(reason)"
        case .invalidResponse:
            return "响应里没有可用的 IP 信息"
        case .allFailed(let reasons):
            return "所有数据源都失败（\(reasons.joined(separator: "；"))）"
        case .simulated:
            return "模拟故障"
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
        case .api(let reason): return reason == "RateLimited" || reason.localizedCaseInsensitiveContains("rate limit")
            || reason.localizedCaseInsensitiveContains("quota")
        case .http(let code): return code == 429
        default: return false
        }
    }

    /// No connection at all: trying another source would not help.
    var isOffline: Bool {
        guard let code = (self as? URLError)?.code else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(code)
    }
}

struct IPAPIClient {
    /// Set IPAPI_LOOKUP_IP=<ip> to look up another IP instead, e.g. to test the mismatch alert.
    private static let lookupIP = ProcessInfo.processInfo.environment["IPAPI_LOOKUP_IP"].nonEmpty

    /// Set IPAPI_FAIL_PROVIDERS=ipapi.co,geojs to make those sources fail, e.g. to test auto-switch.
    private static let simulatedFailures: Set<String> = Set(
        (ProcessInfo.processInfo.environment["IPAPI_FAIL_PROVIDERS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    )

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        // Right after a reconnect DNS/routes are often not ready yet; wait instead of failing at once.
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    func fetch(from provider: IPProvider) async throws -> IPInfo {
        if Self.simulatedFailures.contains(provider.rawValue) { throw IPAPIError.simulated }

        var request = URLRequest(url: provider.url(lookupIP: Self.lookupIP))
        // ipapi.co rate-limits generic user agents (e.g. curl's default) far more aggressively.
        request.setValue("IPLocationMenuBar/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200

        let info: IPInfo
        do {
            info = try provider.decode(data)
        } catch let error as IPAPIError {
            // A readable error body (e.g. "RateLimited") explains more than the bare status code.
            if case .api = error { throw error }
            throw status != 200 ? IPAPIError.http(status) : error
        } catch {
            throw status != 200 ? IPAPIError.http(status) : IPAPIError.invalidResponse
        }
        guard status == 200 else { throw IPAPIError.http(status) }
        return info
    }
}

/// Picks which source to ask: the preferred one first, and with auto-switch on, the others
/// in order when it fails. A failed source sits out a cooldown so the preferred one is
/// retried once it has had time to recover.
@MainActor
final class ProviderRouter {
    private enum Key {
        static let preferred = "preferredProvider"
        static let autoSwitch = "autoSwitchProvider"
    }

    private static let rateLimitCooldown: TimeInterval = 30 * 60
    private static let failureCooldown: TimeInterval = 5 * 60

    private let client = IPAPIClient()
    private let defaults = UserDefaults.standard

    /// Source that produced the current data.
    private(set) var lastSource: IPProvider?
    /// Why the preferred source was not used on the last successful refresh, if it was not.
    private(set) var fallbackReason: String?
    private var cooldownUntil: [IPProvider: Date] = [:]

    var preferred: IPProvider {
        get { defaults.string(forKey: Key.preferred).flatMap(IPProvider.init(rawValue:)) ?? .defaultProvider }
        set {
            defaults.set(newValue.rawValue, forKey: Key.preferred)
            // A manual pick deserves a fresh try even if it failed recently.
            cooldownUntil[newValue] = nil
        }
    }

    var autoSwitch: Bool {
        get { defaults.object(forKey: Key.autoSwitch) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoSwitch) }
    }

    /// When a recently failed source becomes eligible again, or nil if it is not cooling down.
    func cooldownEnd(for provider: IPProvider) -> Date? {
        guard let until = cooldownUntil[provider], until > Date() else { return nil }
        return until
    }

    func fetch() async throws -> IPInfo {
        let preferred = preferred
        guard autoSwitch else {
            // Manual mode: always ask the chosen source and surface its own error,
            // so rate limits still get the longer retry backoff.
            let info = try await client.fetch(from: preferred)
            lastSource = preferred
            fallbackReason = nil
            return info
        }

        var order = [preferred] + IPProvider.allCases.filter { $0 != preferred }
        // Skip sources still cooling down. If all are, try only the one that recovers first
        // rather than hammering every rate-limited service on each retry.
        let ready = order.filter { cooldownEnd(for: $0) == nil }
        if !ready.isEmpty {
            order = ready
        } else if let soonest = order.min(by: { cooldownUntil[$0, default: .distantPast] < cooldownUntil[$1, default: .distantPast] }) {
            order = [soonest]
        }

        var preferredFailure = cooldownEnd(for: preferred).map {
            "前次失败，\(Self.timeFormatter.string(from: $0)) 前暂不使用"
        }
        var failures: [String] = []

        for provider in order {
            do {
                let info = try await client.fetch(from: provider)
                cooldownUntil[provider] = nil
                lastSource = provider
                fallbackReason = provider == preferred ? nil : preferredFailure.map { "\(preferred.displayName) \($0)" }
                log.notice("Fetched from \(provider.rawValue, privacy: .public)")
                return info
            } catch {
                if error.isCancellation || error.isOffline { throw error }
                let reason = error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "。."))
                log.error("\(provider.rawValue, privacy: .public) failed: \(reason, privacy: .public)")
                cooldownUntil[provider] = Date().addingTimeInterval(
                    error.isRateLimited ? Self.rateLimitCooldown : Self.failureCooldown
                )
                if provider == preferred { preferredFailure = reason }
                failures.append("\(provider.displayName)：\(reason)")
            }
        }
        throw IPAPIError.allFailed(failures)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
