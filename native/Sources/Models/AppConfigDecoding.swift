import Foundation

extension AppConfig {
    enum CodingKeys: String, CodingKey {
        case port, activeProviderId, requireToken, gatewayToken, gatewayEnabled, openAtLogin
        case claudeBackup, codexBackup, trayUsage, language, convFontPx, historyDirs, historyActive, connectTargets
        case retry429, insecureSkipVerify, autoUpdate, providers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = c.decodeLegacyPort()
        activeProviderId = try c.decodeIfPresent(String.self, forKey: .activeProviderId)
        requireToken = try c.decodeIfPresent(Bool.self, forKey: .requireToken) ?? false
        gatewayToken = try c.decodeIfPresent(String.self, forKey: .gatewayToken) ?? ""
        gatewayEnabled = try c.decodeIfPresent(Bool.self, forKey: .gatewayEnabled) ?? true
        openAtLogin = try c.decodeIfPresent(Bool.self, forKey: .openAtLogin) ?? false
        claudeBackup = try c.decodeIfPresent(JSONValue.self, forKey: .claudeBackup) ?? .null
        codexBackup = try c.decodeIfPresent(JSONValue.self, forKey: .codexBackup) ?? .null
        trayUsage = c.decodeTrayUsage()
        language = try c.decodeIfPresent(String.self, forKey: .language)
        convFontPx = try c.decodeIfPresent(Int.self, forKey: .convFontPx)
        historyDirs = try c.decodeIfPresent([String].self, forKey: .historyDirs) ?? ["~/.claude"]
        historyActive = try c.decodeIfPresent(String.self, forKey: .historyActive) ?? "all"
        connectTargets = try c.decodeIfPresent([String].self, forKey: .connectTargets) ?? []
        retry429 = c.decodeRetry429()
        insecureSkipVerify = try c.decodeIfPresent(Bool.self, forKey: .insecureSkipVerify) ?? false
        autoUpdate = c.decodeAutoUpdate()
        providers = try c.decodeIfPresent([Provider].self, forKey: .providers) ?? []
        let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
        let knownKeys = Set(CodingKeys.allCases.map(\.stringValue))
        additionalProperties = try Dictionary(uniqueKeysWithValues: dynamic.allKeys.compactMap { key in
            guard !knownKeys.contains(key.stringValue) else { return nil }
            return (key.stringValue, try dynamic.decode(JSONValue.self, forKey: key))
        })
        normalize()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(port, forKey: .port)
        try c.encode(activeProviderId, forKey: .activeProviderId)
        try c.encode(requireToken, forKey: .requireToken)
        try c.encode(gatewayToken, forKey: .gatewayToken)
        try c.encode(gatewayEnabled, forKey: .gatewayEnabled)
        try c.encode(openAtLogin, forKey: .openAtLogin)
        try c.encode(claudeBackup, forKey: .claudeBackup)
        try c.encode(codexBackup, forKey: .codexBackup)
        try c.encode(trayUsage, forKey: .trayUsage)
        try c.encode(language, forKey: .language)
        try c.encode(convFontPx, forKey: .convFontPx)
        try c.encode(historyDirs, forKey: .historyDirs)
        try c.encode(historyActive, forKey: .historyActive)
        try c.encode(connectTargets, forKey: .connectTargets)
        try c.encode(retry429, forKey: .retry429)
        try c.encode(insecureSkipVerify, forKey: .insecureSkipVerify)
        try c.encode(autoUpdate, forKey: .autoUpdate)
        try c.encode(providers, forKey: .providers)

        var dynamic = encoder.container(keyedBy: AnyCodingKey.self)
        for (key, value) in additionalProperties {
            try dynamic.encode(value, forKey: AnyCodingKey(key))
        }
    }
}

private enum TrayUsageCodingKeys: String, CodingKey {
    case enabled, range
}

private enum Retry429CodingKeys: String, CodingKey {
    case enabled, max, baseMs
}

private enum AutoUpdateCodingKeys: String, CodingKey {
    case check, autoDownload
}

private extension KeyedDecodingContainer where Key == AppConfig.CodingKeys {
    /// Legacy releases accepted a decimal string here because the settings form persisted its
    /// text-field value before normalization. Decode that representation without making one
    /// mixed-type scalar invalidate the rest of an otherwise healthy config.
    func decodeLegacyPort() -> Int {
        if let value = try? decode(Int.self, forKey: .port) { return value }
        if let rawValue = try? decode(String.self, forKey: .port),
           let value = Int(rawValue) {
            return value
        }
        return 8_788
    }

    /// The legacy normalizer merged each nested object over its defaults one field at a time.
    /// Synthesized Codable decoding instead requires every non-optional member and used to turn
    /// a partial object into a top-level decode failure. Keep valid siblings and default only the
    /// missing or mistyped member.
    func decodeTrayUsage() -> AppConfig.TrayUsage {
        guard let nested = try? nestedContainer(
            keyedBy: TrayUsageCodingKeys.self,
            forKey: .trayUsage
        ) else { return .init() }
        let enabled = (try? nested.decode(Bool.self, forKey: .enabled)) ?? false
        let decodedRange = (try? nested.decode(String.self, forKey: .range)) ?? "7d"
        let range = ["1d", "7d", "30d", "all"].contains(decodedRange)
            ? decodedRange
            : "7d"
        return .init(enabled: enabled, range: range)
    }

    func decodeRetry429() -> AppConfig.Retry429 {
        guard let nested = try? nestedContainer(
            keyedBy: Retry429CodingKeys.self,
            forKey: .retry429
        ) else { return .init() }
        return .init(
            enabled: (try? nested.decode(Bool.self, forKey: .enabled)) ?? true,
            max: (try? nested.decode(Int.self, forKey: .max)) ?? 3,
            baseMs: (try? nested.decode(Int.self, forKey: .baseMs)) ?? 500
        )
    }

    func decodeAutoUpdate() -> AppConfig.AutoUpdate {
        guard let nested = try? nestedContainer(
            keyedBy: AutoUpdateCodingKeys.self,
            forKey: .autoUpdate
        ) else { return .init() }
        return .init(
            check: (try? nested.decode(Bool.self, forKey: .check)) ?? true,
            autoDownload: (try? nested.decode(Bool.self, forKey: .autoDownload)) ?? true
        )
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) { self.init(stringValue) }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension AppConfig.CodingKeys {
    static var allCases: [Self] {
        [
            .port, .activeProviderId, .requireToken, .gatewayToken, .gatewayEnabled,
            .openAtLogin, .claudeBackup, .codexBackup, .trayUsage, .language, .convFontPx,
            .historyDirs, .historyActive, .connectTargets, .retry429,
            .insecureSkipVerify, .autoUpdate, .providers,
        ]
    }
}
