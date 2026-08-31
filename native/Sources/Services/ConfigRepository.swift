import Foundation

struct ConfigRepository {
    let configURL: URL
    private let fileManager: FileManager

    init(configURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.configURL = configURL ?? Self.defaultConfigURL(fileManager: fileManager)
    }

    static func defaultConfigURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment["CCBUD_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("config.json")
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".ccbud", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    func load() throws -> AppConfig {
        guard fileManager.fileExists(atPath: configURL.path) else { return AppConfig() }
        var config = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: configURL))
        config.normalize()
        return config
    }

    func save(_ input: AppConfig) throws {
        let data = try serialized(input)
        // Preserve deliberate dotfile symlinks (for example into a managed dotfiles tree) by
        // replacing the resolved target rather than renaming over the link itself.
        let destination = configURL.resolvingSymlinksInPath().standardizedFileURL
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try SecureAtomicFile.write(data, to: destination, fileManager: fileManager)
    }

    func serialized(_ input: AppConfig) throws -> Data {
        var config = input
        config.normalize()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(config)
    }
}
