//
//  OpenCodeAPIService.swift
//  JustaUsageBar
//
//  Reads OpenCode Go credentials and fetches usage. OpenCode owns every
//  sign-in; this service only reads, and never refreshes a token.
//

import Foundation
import SQLite3

// MARK: - OpenCode Usage Data Model

nonisolated struct OpenCodeUsageData {
    /// The rolling window OpenCode Go reports (the five-hour window).
    var rollingUsedPercent: Double = 0
    var rollingResetAt: Date?
    var weeklyUsedPercent: Double = 0
    var weeklyResetAt: Date?
    var monthlyUsedPercent: Double = 0
    var monthlyResetAt: Date?
    var hasMonthly: Bool = false

    var timeUntilRollingReset: String {
        guard let resetAt = rollingResetAt else { return "--" }
        return formatTimeUntil(resetAt)
    }

    var timeUntilWeeklyReset: String {
        guard let resetAt = weeklyResetAt else { return "--" }
        return formatTimeUntil(resetAt)
    }

    var timeUntilMonthlyReset: String {
        guard let resetAt = monthlyResetAt else { return "--" }
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

    static let placeholder = OpenCodeUsageData()
}

// MARK: - OpenCode API Service

@ProviderActor
final class OpenCodeAPIService {
    static let shared = OpenCodeAPIService()

    private static let usageURLString = "https://opencode.ai/zen/go/v1/usage"

    nonisolated struct OpenCodeCredentials {
        var apiKey: String
        var source: Source

        nonisolated enum Source: String {
            case environment
            case config
            case database
            case legacyAuthFile
        }
    }

    private var cachedCredentials: [OpenCodeCredentials]?
    private var lastCredentialCheck: Date?
    private let credentialCacheTTL: TimeInterval = 300

    private init() {}

    // MARK: - Credential Discovery

    /// Priority: `OPENCODE_API_KEY`, then `provider.opencode-go.options.apiKey`
    /// (legacy alias `provider.opencode`) in OpenCode's config, then API-key
    /// logins in OpenCode's credential database, then OpenCode 1's auth.json.
    func loadCredentialCandidates() -> [OpenCodeCredentials] {
        if let lastCredentialCheck,
           Date().timeIntervalSince(lastCredentialCheck) < credentialCacheTTL {
            return cachedCredentials ?? []
        }

        var candidates: [OpenCodeCredentials] = []
        if let envKey = ProcessInfo.processInfo.environment["OPENCODE_API_KEY"], !envKey.isEmpty {
            candidates.append(OpenCodeCredentials(apiKey: envKey, source: .environment))
        }
        if let configKey = readConfigKey() {
            candidates.append(OpenCodeCredentials(apiKey: configKey, source: .config))
        }
        candidates.append(contentsOf: readDatabaseKeys())
        if let legacyKey = readLegacyAuthFileKey() {
            candidates.append(OpenCodeCredentials(apiKey: legacyKey, source: .legacyAuthFile))
        }

        cachedCredentials = candidates
        lastCredentialCheck = Date()
        return candidates
    }

    var hasCredentials: Bool {
        !loadCredentialCandidates().isEmpty
    }

    func clearCache() {
        cachedCredentials = nil
        lastCredentialCheck = nil
    }

    // MARK: - Fetch Usage

    func fetchUsage() async throws -> OpenCodeUsageData {
        let candidates = loadCredentialCandidates()
        guard !candidates.isEmpty else {
            throw APIError.noCredentials
        }

        // An expired key must not hide a live one: try each stored key in
        // order and keep the first answer. Auth failures fall through.
        var lastAuthError: APIError = .noCredentials
        for creds in candidates {
            do {
                return try await fetchUsage(creds: creds)
            } catch let error as APIError {
                switch error {
                case .unauthorized, .cliSignInExpired:
                    lastAuthError = error
                    continue
                default:
                    throw error
                }
            }
        }
        throw lastAuthError
    }

    private func fetchUsage(creds: OpenCodeCredentials) async throws -> OpenCodeUsageData {
        guard let url = URL(string: Self.usageURLString) else {
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
            return try Self.parseUsageResponse(data)
        case 429:
            throw APIError.rateLimited(retryAfter: HTTPRetryAfter.date(from: httpResponse))
        case 401, 403:
            // A stored key OpenCode no longer accepts. The credential cache is
            // not cleared here: every candidate is tried per fetch, and the
            // database rereads happen on its own cadence.
            throw APIError.cliSignInExpired(tool: "OpenCode")
        default:
            throw APIError.unknown(httpResponse.statusCode)
        }
    }

    // MARK: - Parse Response

    nonisolated static func parseUsageResponse(_ data: Data) throws -> OpenCodeUsageData {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any] else {
            throw APIError.decodingError(NSError(
                domain: "JSON",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "OpenCode usage returned an unexpected response shape"]
            ))
        }

        var result = OpenCodeUsageData()
        if let rolling = usage["rolling"] as? [String: Any] {
            let window = Self.normalizeWindow(rolling)
            result.rollingUsedPercent = window.usedPercent
            result.rollingResetAt = window.resetAt
        }
        if let weekly = usage["weekly"] as? [String: Any] {
            let window = Self.normalizeWindow(weekly)
            result.weeklyUsedPercent = window.usedPercent
            result.weeklyResetAt = window.resetAt
        }
        if let monthly = usage["monthly"] as? [String: Any] {
            let window = Self.normalizeWindow(monthly)
            result.monthlyUsedPercent = window.usedPercent
            result.monthlyResetAt = window.resetAt
            result.hasMonthly = true
        }
        return result
    }

    /// `percent` is the used percentage; `status` "rate-limited" means the
    /// window is exhausted (100% used). `resetsAt` is ISO-8601.
    nonisolated static func normalizeWindow(_ window: [String: Any]) -> (usedPercent: Double, resetAt: Date?) {
        let usedPercent: Double
        if let status = window["status"] as? String, status == "rate-limited" {
            usedPercent = 100
        } else if let percent = window["percent"] as? Double {
            usedPercent = min(max(percent, 0), 100)
        } else if let percent = window["percent"] as? Int {
            usedPercent = min(max(Double(percent), 0), 100)
        } else {
            usedPercent = 0
        }
        let resetAt = (window["resetsAt"] as? String).flatMap { ISO8601Timestamp.date(from: $0) }
        return (usedPercent, resetAt)
    }

    // MARK: - Config File Key

    /// `provider.opencode-go.options.apiKey`, falling back to the legacy
    /// `provider.opencode` alias, from `opencode.json(c)` (JSONC tolerated).
    private func readConfigKey() -> String? {
        for file in ["opencode.json", "opencode.jsonc"] {
            guard let url = configDirectory?.appendingPathComponent(file),
                  FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: Self.sanitizedJSONC(data)) as? [String: Any]
            else { continue }

            for providerId in ["opencode-go", "opencode"] {
                if let key = Self.configKey(at: ["provider", providerId, "options", "apiKey"], in: json) {
                    return key
                }
            }
        }
        return nil
    }

    private var configDirectory: URL? {
        let environment = ProcessInfo.processInfo.environment
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("opencode")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/opencode")
    }

    private static func configKey(at path: [String], in json: [String: Any]) -> String? {
        var current: Any = json
        for segment in path {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[segment] ?? NSNull()
        }
        guard let key = current as? String, !key.isEmpty else { return nil }
        return key
    }

    /// Strips comments and trailing commas so JSONC parses as JSON, without
    /// touching `//` inside strings (config files hold URLs).
    nonisolated static func sanitizedJSONC(_ data: Data) -> Data {
        guard let source = String(data: data, encoding: .utf8) else { return data }
        var withoutComments = [Character]()
        withoutComments.reserveCapacity(source.count)
        var inString = false
        var escaped = false

        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if inString {
                withoutComments.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = source.index(after: index)
                continue
            }
            if character == "\"" {
                inString = true
                withoutComments.append(character)
                index = source.index(after: index)
                continue
            }
            if character == "/", source.index(after: index) < source.endIndex {
                let next = source[source.index(after: index)]
                if next == "/" {
                    while index < source.endIndex, source[index] != "\n" {
                        index = source.index(after: index)
                    }
                    continue
                }
                if next == "*" {
                    index = source.index(after: index)
                    index = source.index(after: index)
                    while index < source.endIndex {
                        if source[index] == "*", source.index(after: index) < source.endIndex,
                           source[source.index(after: index)] == "/" {
                            index = source.index(after: index)
                            index = source.index(after: index)
                            break
                        }
                        index = source.index(after: index)
                    }
                    continue
                }
            }
            withoutComments.append(character)
            index = source.index(after: index)
        }

        // Trailing commas before } or ].
        var result = [Character]()
        result.reserveCapacity(withoutComments.count)
        var position = withoutComments.startIndex
        while position < withoutComments.endIndex {
            let character = withoutComments[position]
            if character == "," {
                var lookahead = withoutComments.index(after: position)
                while lookahead < withoutComments.endIndex,
                      withoutComments[lookahead] == " " || withoutComments[lookahead] == "\n"
                      || withoutComments[lookahead] == "\t" || withoutComments[lookahead] == "\r" {
                    lookahead = withoutComments.index(after: lookahead)
                }
                if lookahead < withoutComments.endIndex,
                   withoutComments[lookahead] == "}" || withoutComments[lookahead] == "]" {
                    position = lookahead
                    continue
                }
            }
            result.append(character)
            position = withoutComments.index(after: position)
        }
        return Data(String(result).utf8)
    }

    // MARK: - Credential Database

    /// API-key logins from OpenCode 2's credential database, `opencode-go`
    /// rows first (the legacy `opencode` alias follows), active rows first.
    private func readDatabaseKeys() -> [OpenCodeCredentials] {
        guard let dbPath = credentialDatabasePath,
              FileManager.default.fileExists(atPath: dbPath.path) else {
            return []
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(dbPath.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close_v2(database)
            return []
        }
        defer { sqlite3_close_v2(database) }

        let query = """
            SELECT integration_id, value FROM credential
            WHERE integration_id IN ('opencode-go', 'opencode')
            ORDER BY active DESC, time_updated DESC, id DESC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var goKeys: [OpenCodeCredentials] = []
        var aliasKeys: [OpenCodeCredentials] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let integrationId = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                  let valueText = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
                  let value = try? JSONSerialization.jsonObject(with: Data(valueText.utf8)) as? [String: Any],
                  (value["type"] as? String) == "key" || (value["type"] as? String) == "api",
                  let key = value["key"] as? String, !key.isEmpty
            else { continue }

            let credential = OpenCodeCredentials(apiKey: key, source: .database)
            if integrationId == "opencode-go" {
                goKeys.append(credential)
            } else {
                aliasKeys.append(credential)
            }
        }

        // The same key can sit under both ids; say it once.
        var seen = Set<String>()
        return (goKeys + aliasKeys).filter { seen.insert($0.apiKey).inserted }
    }

    private var credentialDatabasePath: URL? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["OPENCODE_DB"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("opencode/opencode.db")
        }
        return home.appendingPathComponent(".local/share/opencode/opencode.db")
    }

    // MARK: - OpenCode 1 auth.json

    /// `{ "opencode-go": { "type": "api", "key": "..." }, ... }`
    private func readLegacyAuthFileKey() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let authPath = home.appendingPathComponent(".local/share/opencode/auth.json")
        guard let data = try? Data(contentsOf: authPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        for providerId in ["opencode-go", "opencode"] {
            guard let entry = json[providerId] as? [String: Any],
                  let type = entry["type"] as? String, type == "api" || type == "key",
                  let key = entry["key"] as? String, !key.isEmpty
            else { continue }
            return key
        }
        return nil
    }
}
