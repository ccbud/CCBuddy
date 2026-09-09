import Darwin
import Foundation
import XCTest
@testable import CCBuddy

/// Real Network listeners, with no Bifrost process, readiness stub, fixed port, or timing delay.
@MainActor
final class LegacyGatewayProxyLifecycleTests: XCTestCase {
    func testNeverStartedAndInvalidStartCanBeStoppedRepeatedly() async throws {
        let unused = makeProxy()
        await stopConcurrently(unused)

        let invalid = makeProxy()
        do {
            try await invalid.start(publicPort: 0, backendPort: 1)
            XCTFail("An invalid public port must not start a listener")
        } catch {}
        await stopConcurrently(invalid)
    }

    func testBindFailureCanBeStoppedWithoutCancellingThePortOwner() async throws {
        let port = try ClaudeCLIE2ETestSupport.availableLoopbackPort()
        let owner = makeProxy()
        addTeardownBlock { owner.stop(); await owner.waitUntilStopped() }
        try await owner.start(publicPort: port, backendPort: port)
        let rejected = makeProxy()
        do {
            try await rejected.start(publicPort: port, backendPort: port)
            XCTFail("The second proxy must not share an occupied endpoint")
        } catch {}
        await stopConcurrently(rejected)
        XCTAssertFalse(canBind(port), "Disposing the failed proxy must not stop its healthy predecessor")

        await stopConcurrently(owner)
        XCTAssertTrue(canBind(port))
        let replacement = makeProxy()
        addTeardownBlock { replacement.stop(); await replacement.waitUntilStopped() }
        try await replacement.start(publicPort: port, backendPort: port)
    }

    func testStoppedProxyCannotStartAfterItsDisposalHasCompleted() async throws {
        let port = try ClaudeCLIE2ETestSupport.availableLoopbackPort()
        let proxy = makeProxy()
        await stopConcurrently(proxy)
        do {
            try await proxy.start(publicPort: port, backendPort: port)
            XCTFail("A retired generation must never install a late listener")
        } catch {}
        XCTAssertTrue(canBind(port), "Stopping before async startup begins must be terminal")
        await stopConcurrently(proxy)
    }

    func testConcurrentStartAndStopCannotInstallAListenerAfterDisposal() async throws {
        let port = try ClaudeCLIE2ETestSupport.availableLoopbackPort()
        for generation in 0..<100 {
            let proxy = makeProxy()
            async let startup: Void = proxy.start(publicPort: port, backendPort: port)
            await stopConcurrently(proxy)
            // Either ready won the race or stop rejected the async start. Both outcomes
            // must leave no listener after disposal, including a start resumed afterwards.
            do { try await startup } catch {}
            XCTAssertTrue(canBind(port), "Generation \(generation) installed a listener after stop returned")
            await stopConcurrently(proxy)
        }
    }

    func testRepeatedSamePortReopenWaitsForActualListenerCancellation() async throws {
        let port = try ClaudeCLIE2ETestSupport.availableLoopbackPort()
        for generation in 0..<100 {
            let proxy = makeProxy()
            do {
                try await proxy.start(publicPort: port, backendPort: port)
            } catch {
                proxy.stop()
                await proxy.waitUntilStopped()
                throw error
            }
            proxy.stop()
            await proxy.waitUntilStopped()
            XCTAssertTrue(canBind(port), "Generation \(generation) returned before releasing its listener")
            // Repeated stops and waits must also work after the .cancelled callback was delivered.
            proxy.stop()
            await proxy.waitUntilStopped()
        }
    }

    func testConcurrentStopWaitersAllFinishBeforeTheSamePortReopens() async throws {
        let port = try ClaudeCLIE2ETestSupport.availableLoopbackPort()
        let proxy = makeProxy()
        addTeardownBlock { proxy.stop(); await proxy.waitUntilStopped() }
        try await proxy.start(publicPort: port, backendPort: port)
        await stopConcurrently(proxy)
        XCTAssertTrue(canBind(port))
        let replacement = makeProxy()
        addTeardownBlock { replacement.stop(); await replacement.waitUntilStopped() }
        try await replacement.start(publicPort: port, backendPort: port)
    }

    func testAcceptedConnectionDoesNotPreventImmediateSamePortReopen() async throws {
        let backend = try ListeningSocket()
        defer { backend.close() }
        let port = try ClaudeCLIE2ETestSupport.availableLoopbackPort()
        let received = expectation(description: "The real proxy accepted and parsed a request")
        let proxy = LegacyGatewayCompatibilityProxy(modelRouting: .init(provider: nil)) { activity in
            if activity == .requestReceived { received.fulfill() }
        }
        addTeardownBlock { proxy.stop(); await proxy.waitUntilStopped() }
        try await proxy.start(publicPort: port, backendPort: backend.port)
        let client = try connectClient(port: port)
        defer { Darwin.close(client) }
        let request = Data("POST /responses HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{}".utf8)
        let sent = request.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
        XCTAssertEqual(sent, request.count)
        await fulfillment(of: [received], timeout: 3)
        await stopConcurrently(proxy)
        let replacement = makeProxy()
        addTeardownBlock { replacement.stop(); await replacement.waitUntilStopped() }
        // Keep the original client open until after the new listener is ready.
        try await replacement.start(publicPort: port, backendPort: backend.port)
    }

    func testSupervisorLaunchFailureDisposesListenerBeforeReturning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-listener-launch-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("invalid-executable")
        try Data("not an executable image".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let supervisor = BifrostSupervisor(environment: [
            "CCBUD_HOME": root.appendingPathComponent("home").path,
            "CCBUD_BIFROST_BINARY": executable.path,
        ])
        var config = AppConfig.fixture
        config.port = try ClaudeCLIE2ETestSupport.availableLoopbackPort()
        for _ in 0..<12 {
            do {
                try await supervisor.start(config: config)
                XCTFail("The invalid executable must fail after listener startup")
            } catch let error as BifrostError {
                guard case .startupFailed = error else { throw error }
            }
            XCTAssertTrue(canBind(config.port), "Supervisor disposal must await the proxy cancellation latch")
        }
        async let firstStop: Void = supervisor.stop()
        async let secondStop: Void = supervisor.stop()
        _ = await (firstStop, secondStop)
        let state = await supervisor.state
        XCTAssertEqual(state, .stopped)
    }

    private func makeProxy() -> LegacyGatewayCompatibilityProxy {
        LegacyGatewayCompatibilityProxy(modelRouting: .init(provider: nil), onActivity: { _ in })
    }

    private func stopConcurrently(_ proxy: LegacyGatewayCompatibilityProxy) async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    proxy.stop()
                    await proxy.waitUntilStopped()
                }
            }
        }
    }

    private func canBind(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = loopbackAddress(port: port)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func connectClient(port: Int) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = loopbackAddress(port: port)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { Darwin.close(descriptor); throw POSIXError(.ECONNREFUSED) }
        return descriptor
    }
}

private func loopbackAddress(port: Int) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    return address
}

private final class ListeningSocket {
    let port: Int
    private var descriptor: Int32

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = loopbackAddress(port: 0)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolved = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard resolved == 0 else { Darwin.close(descriptor); throw POSIXError(.EADDRNOTAVAIL) }
        self.descriptor = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    func close() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }

    deinit { close() }
}
