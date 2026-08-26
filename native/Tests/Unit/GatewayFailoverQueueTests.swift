import XCTest

@testable import CCBuddy

/// While automatic failover is on, the queue is the gateway's whole route set — tried strictly in
/// order — so the edits that build it are the difference between "the next provider takes over" and
/// "the gateway has nowhere to send the request".
@MainActor
final class GatewayFailoverQueueTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-failover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func provider(_ id: String) -> Provider {
        Provider(id: id, name: id.capitalized, baseUrl: "https://\(id).example.com/v1")
    }

    private func makeModel(_ config: AppConfig) throws -> AppModel {
        let repository = ConfigRepository(configURL: root.appendingPathComponent("config.json"))
        try repository.save(config)
        return AppModel(
            repository: repository,
            supervisor: BifrostSupervisor(environment: ["CCBUD_HOME": root.path]),
            environment: ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"]
        )
    }

    private func baseConfig() -> AppConfig {
        AppConfig(
            activeProviderId: "alpha",
            gatewayEnabled: false,
            providers: [provider("alpha"), provider("beta"), provider("gamma")]
        )
    }

    func testEnablingFailoverSeedsTheQueueWithTheActiveProvider() async throws {
        let model = try makeModel(baseConfig())

        await model.setGatewayFailoverEnabled(true)

        XCTAssertTrue(model.config.gatewayFailover.enabled)
        XCTAssertEqual(
            model.config.gatewayFailover.providerIds,
            ["alpha"],
            "an enabled but empty queue would leave the gateway with no route at all"
        )
        XCTAssertEqual(model.config.gatewayProviders.map(\.id), ["alpha"])
        await model.shutdown()
    }

    func testAddedProvidersJoinTheBackOfTheQueueAndRouteInThatOrder() async throws {
        let model = try makeModel(baseConfig())
        await model.setGatewayFailoverEnabled(true)

        await model.addFailoverProvider("gamma")
        await model.addFailoverProvider("beta")

        XCTAssertEqual(model.config.gatewayFailover.providerIds, ["alpha", "gamma", "beta"])
        XCTAssertEqual(model.config.gatewayProviders.map(\.id), ["alpha", "gamma", "beta"])
        XCTAssertEqual(model.config.gatewayPrimaryProvider?.id, "alpha")
        await model.shutdown()
    }

    func testAddingIgnoresDuplicatesAndProvidersThatDoNotExist() async throws {
        let model = try makeModel(baseConfig())
        await model.setGatewayFailoverEnabled(true)

        await model.addFailoverProvider("alpha")
        await model.addFailoverProvider("nobody")

        XCTAssertEqual(model.config.gatewayFailover.providerIds, ["alpha"])
        await model.shutdown()
    }

    func testMovingAnEntryChangesWhichProviderIsTriedFirst() async throws {
        let model = try makeModel(baseConfig())
        await model.setGatewayFailoverEnabled(true)
        await model.addFailoverProvider("beta")
        await model.addFailoverProvider("gamma")

        await model.moveFailoverProvider("gamma", offset: -1)

        XCTAssertEqual(model.config.gatewayFailover.providerIds, ["alpha", "gamma", "beta"])

        await model.moveFailoverProvider("gamma", offset: -1)
        XCTAssertEqual(model.config.gatewayFailover.providerIds, ["gamma", "alpha", "beta"])
        XCTAssertEqual(model.config.gatewayPrimaryProvider?.id, "gamma")
        await model.shutdown()
    }

    func testMovingPastEitherEndIsANoOp() async throws {
        let model = try makeModel(baseConfig())
        await model.setGatewayFailoverEnabled(true)
        await model.addFailoverProvider("beta")

        await model.moveFailoverProvider("alpha", offset: -1)
        await model.moveFailoverProvider("beta", offset: 1)

        XCTAssertEqual(model.config.gatewayFailover.providerIds, ["alpha", "beta"])
        await model.shutdown()
    }

    func testRemovingTheLastEntryFallsBackToTheActiveProviderRatherThanNoRoute() async throws {
        let model = try makeModel(baseConfig())
        await model.setGatewayFailoverEnabled(true)

        await model.removeFailoverProvider("alpha")

        XCTAssertEqual(
            model.config.gatewayFailover.providerIds,
            ["alpha"],
            "normalization reseeds the queue, so emptying it cannot silence the gateway"
        )
        await model.shutdown()
    }

    func testRemovingKeepsTheRestOfTheOrder() async throws {
        let model = try makeModel(baseConfig())
        await model.setGatewayFailoverEnabled(true)
        await model.addFailoverProvider("beta")
        await model.addFailoverProvider("gamma")

        await model.removeFailoverProvider("beta")

        XCTAssertEqual(model.config.gatewayFailover.providerIds, ["alpha", "gamma"])
        await model.shutdown()
    }

    func testTurningFailoverOffRestoresTheSingleActiveRouteAndKeepsTheQueue() async throws {
        let model = try makeModel(baseConfig())
        await model.setGatewayFailoverEnabled(true)
        await model.addFailoverProvider("beta")

        await model.setGatewayFailoverEnabled(false)

        XCTAssertFalse(model.config.gatewayFailover.enabled)
        XCTAssertEqual(
            model.config.gatewayFailover.providerIds,
            ["alpha", "beta"],
            "the queue is remembered so switching failover back on does not start from scratch"
        )
        XCTAssertEqual(model.config.gatewayProviders.map(\.id), ["alpha"])
        await model.shutdown()
    }

    func testTheQueueSurvivesAReload() async throws {
        let model = try makeModel(baseConfig())
        await model.setGatewayFailoverEnabled(true)
        await model.addFailoverProvider("gamma")
        await model.shutdown()

        let repository = ConfigRepository(configURL: root.appendingPathComponent("config.json"))
        let reloaded = try repository.load()
        XCTAssertTrue(reloaded.gatewayFailover.enabled)
        XCTAssertEqual(reloaded.gatewayFailover.providerIds, ["alpha", "gamma"])
    }

    func testChoosingAProviderWhileFailoverIsOnMakesItTheHeadOfTheQueue() async throws {
        let model = try makeModel(baseConfig())
        await model.setGatewayFailoverEnabled(true)
        await model.addFailoverProvider("beta")

        await model.setActiveProvider("gamma")

        XCTAssertEqual(
            model.config.gatewayFailover.providerIds,
            ["gamma", "alpha", "beta"],
            "otherwise the row the list marks as in use is not the one taking the traffic"
        )
        XCTAssertEqual(model.config.activeProviderId, "gamma")
        await model.shutdown()
    }

    func testReorderingTheQueueMovesWhichProviderCountsAsActive() async throws {
        let model = try makeModel(baseConfig())
        await model.setGatewayFailoverEnabled(true)
        await model.addFailoverProvider("beta")

        await model.moveFailoverProvider("beta", offset: -1)

        XCTAssertEqual(model.config.gatewayFailover.providerIds, ["beta", "alpha"])
        XCTAssertEqual(model.config.activeProviderId, "beta")
        await model.shutdown()
    }

    func testRemovingTheHeadPromotesTheNextProvider() async throws {
        let model = try makeModel(baseConfig())
        await model.setGatewayFailoverEnabled(true)
        await model.addFailoverProvider("beta")

        await model.removeFailoverProvider("alpha")

        XCTAssertEqual(model.config.gatewayFailover.providerIds, ["beta"])
        XCTAssertEqual(model.config.activeProviderId, "beta")
        await model.shutdown()
    }

    func testTurningFailoverOffLeavesTheLastHeadActive() async throws {
        let model = try makeModel(baseConfig())
        await model.setGatewayFailoverEnabled(true)
        await model.addFailoverProvider("gamma")
        await model.moveFailoverProvider("gamma", offset: -1)

        await model.setGatewayFailoverEnabled(false)

        XCTAssertEqual(
            model.config.activeProviderId,
            "gamma",
            "the provider that was taking requests keeps taking them when the queue stops routing"
        )
        XCTAssertEqual(model.config.gatewayProviders.map(\.id), ["gamma"])
        await model.shutdown()
    }

    func testDeletingAProviderDropsItFromTheQueue() async throws {
        let model = try makeModel(baseConfig())
        await model.setGatewayFailoverEnabled(true)
        await model.addFailoverProvider("beta")

        await model.deleteProvider("beta")

        XCTAssertEqual(model.config.gatewayFailover.providerIds, ["alpha"])
        await model.shutdown()
    }
}
