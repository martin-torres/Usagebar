//
//  CommandCodeAPIService.swift
//  JustaUsageBar
//
//  Reads Command Code credentials and fetches usage
//

import Foundation

// MARK: - Command Code Usage Data Model

nonisolated struct CommandCodeUsageData {
    var fiveHourUsedPercent: Double = 0
    var fiveHourResetAt: Date?
    var weeklyUsedPercent: Double = 0
    var weeklyResetAt: Date?
    /// Prepaid credits left on the account, shown on the panel card.
    var creditsRemaining: Double?
    var hasFiveHour: Bool = false
    var hasWeekly: Bool = false

    var timeUntilFiveHourReset: String {
        guard let resetAt = fiveHourResetAt else { return "--" }
        return formatTimeUntil(resetAt)
    }

    var timeUntilWeeklyReset: String {
        guard let resetAt = weeklyResetAt else { return "--" }
        return formatTimeUntil(resetAt)
    }

    private func formatTimeUntil(_ date: Date) -> String {
        let now = Date()
        guard date > now else { return "Now" }
        let interval = date.timeIntervalSince(now)
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours >= 24 {
            return "\(hours / 24)d \(hours % 24)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    static let placeholder = CommandCodeUsageData()
}

// MARK: - Command Code API Service

@ProviderActor
final class CommandCodeAPIService {
    static let shared = CommandCodeAPIService()

    private static let apiBase = "https://api.commandcode.ai/alpha"

    nonisolated struct CommandCodeCredentials {
        var apiKey: String
        var source: Source

        nonisolated enum Source {
            case cli
            case environment
            case saved
        }
    }

    private var cachedCredentials: CommandCodeCredentials?
    private var lastCredentialCheck: Date?
    private let credentialCacheTTL: TimeInterval = 300

    private init() {}

    // MARK: - Credential Discovery

    /// Priority: Command Code CLI's own `apiKey` in `~/.commandcode/auth.json`,
    /// then `CMD_API_KEY` from the environment, then a key saved in Usagebar.
    func loadCredentials() -> CommandCodeCredentials? {
        if let lastCredentialCheck,
           Date().timeIntervalSince(lastCredentialCheck) < credentialCacheTTL {
            return cachedCredentials
        }

        let credentials = discoverCredentials()
        cachedCredentials = credentials
        lastCredentialCheck = Date()
        return credentials
    }

    private func discoverCredentials() -> CommandCodeCredentials? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let authPath = homeDir.appendingPathComponent(".commandcode/auth.json")

        if let data = try? Data(contentsOf: authPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let apiKey = json["apiKey"] as? String, !apiKey.isEmpty {
            return CommandCodeCredentials(apiKey: apiKey, source: .cli)
        }

        if let envKey = ProcessInfo.processInfo.environment["CMD_API_KEY"], !envKey.isEmpty {
            return CommandCodeCredentials(apiKey: envKey, source: .environment)
        }

        if let savedKey = CredentialStorage.shared.commandCodeAPIKey, !savedKey.isEmpty {
            return CommandCodeCredentials(apiKey: savedKey, source: .saved)
        }

        return nil
    }

    var hasCredentials: Bool {
        loadCredentials() != nil
    }

    func clearCache() {
        cachedCredentials = nil
        lastCredentialCheck = nil
    }

    // MARK: - Fetch Usage

    func fetchUsage() async throws -> CommandCodeUsageData {
        try await fetchUsage(allowRediscovery: true)
    }

    private func fetchUsage(allowRediscovery: Bool) async throws -> CommandCodeUsageData {
        guard let creds = loadCredentials() else {
            throw APIError.noCredentials
        }

        let identityData = try await getData(path: "whoami?limits=1", creds: creds, allowRediscovery: allowRediscovery)
        guard let identity = try? JSONSerialization.jsonObject(with: identityData) as? [String: Any],
              (identity["success"] as? Bool) == true else {
            throw APIError.decodingError(invalidResponse("whoami"))
        }

        var creditsPath = "billing/credits"
        if let org = identity["org"] as? [String: Any],
           let orgId = org["id"] as? String, !orgId.isEmpty {
            let encoded = orgId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? orgId
            creditsPath = "billing/credits?orgId=\(encoded)"
        }

        let creditsData = try await getData(path: creditsPath, creds: creds, allowRediscovery: false)
        return try Self.parseCreditsResponse(creditsData)
    }

    private func getData(path: String, creds: CommandCodeCredentials, allowRediscovery: Bool) async throws -> Data {
        guard let url = URL(string: "\(Self.apiBase)/\(path)") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(creds.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Usagebar/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await ProviderHTTP.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknown(0)
        }

        switch httpResponse.statusCode {
        case 200:
            return data
        case 429:
            throw APIError.rateLimited(retryAfter: HTTPRetryAfter.date(from: httpResponse))
        case 401, 403:
            // The CLI owns this sign-in. Reread its file in case it renewed the
            // key; otherwise wait for the CLI to.
            clearCache()
            if allowRediscovery, let reloaded = loadCredentials(), reloaded.apiKey != creds.apiKey {
                return try await getData(path: path, creds: reloaded, allowRediscovery: false)
            }
            throw creds.source == .cli
                ? APIError.cliSignInExpired(tool: "Command Code")
                : APIError.unauthorized
        default:
            throw APIError.unknown(httpResponse.statusCode)
        }
    }

    // MARK: - Parse Response

    nonisolated static func parseCreditsResponse(_ data: Data) throws -> CommandCodeUsageData {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windowLimits = json["windowLimits"] as? [String: Any] else {
            throw APIError.decodingError(NSError(
                domain: "JSON",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Command Code billing/credits returned an unexpected response shape"]
            ))
        }

        var usage = CommandCodeUsageData()
        if let fiveHour = windowLimits["fiveHour"] as? [String: Any],
           let cap = number(fiveHour["cap"]), cap > 0,
           let used = number(fiveHour["used"]) {
            usage.fiveHourUsedPercent = min(used / cap * 100, 100)
            usage.fiveHourResetAt = epochMilliDate(fiveHour["resetAt"])
            usage.hasFiveHour = true
        }
        if let weekly = windowLimits["weekly"] as? [String: Any],
           let cap = number(weekly["cap"]), cap > 0,
           let used = number(weekly["used"]) {
            usage.weeklyUsedPercent = min(used / cap * 100, 100)
            usage.weeklyResetAt = epochMilliDate(weekly["resetAt"])
            usage.hasWeekly = true
        }
        if let credits = json["credits"] as? [String: Any],
           let monthly = number(credits["monthlyCredits"]) {
            usage.creditsRemaining = monthly
        }
        return usage
    }

    nonisolated static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    /// Command Code reports resets as epoch milliseconds.
    nonisolated static func epochMilliDate(_ value: Any?) -> Date? {
        guard let milli = number(value), milli > 0 else { return nil }
        return Date(timeIntervalSince1970: milli / 1000)
    }

    private func invalidResponse(_ endpoint: String) -> NSError {
        NSError(
            domain: "JSON",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Command Code \(endpoint) returned an unexpected response shape"]
        )
    }
}
