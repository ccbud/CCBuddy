import CryptoKit
import Foundation
import XCTest

@testable import CCBuddy

/// Reading a universal binary one slice at a time.
///
/// The bundled gateway helper is two published downloads joined by `lipo`, so the file as a whole
/// has a digest nobody upstream ever published. Only the slices can be pinned, and a checker that
/// silently returned nothing for a fat file would report a release as unverifiable — which is how
/// the first universal build failed its own packaged self-check.
///
/// The fixtures are assembled byte by byte rather than borrowed from `/bin`: a fat header is a
/// fixed big-endian layout, and building it here means the expected digests are known exactly
/// instead of depending on whichever architectures a system binary happens to ship this year.
final class MachOSliceDigestTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-macho-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private static let armCPU: UInt32 = 0x0100_000C  // CPU_TYPE_ARM64
    private static let intelCPU: UInt32 = 0x0100_0007  // CPU_TYPE_X86_64

    private func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    /// A thin Mach-O: only the magic and CPU type are ever read, so the rest is filler.
    private func thinBinary(cpu: UInt32, body: Data) -> Data {
        var bytes = withUnsafeBytes(of: UInt32(0xFEED_FACF)) { Data($0) }  // MH_MAGIC_64, host order
        bytes.append(withUnsafeBytes(of: cpu) { Data($0) })
        bytes.append(body)
        return bytes
    }

    /// A fat container in the on-disk layout: a big-endian header, one entry per slice, then the
    /// slices themselves at the offsets the entries name.
    private func fatBinary(_ slices: [(cpu: UInt32, payload: Data)]) -> Data {
        var header = bigEndian(0xCAFE_BABE)
        header.append(bigEndian(UInt32(slices.count)))
        var offset = UInt32(8 + slices.count * 20)
        var body = Data()
        for slice in slices {
            header.append(bigEndian(slice.cpu))
            header.append(bigEndian(0))  // cpusubtype
            header.append(bigEndian(offset))
            header.append(bigEndian(UInt32(slice.payload.count)))
            header.append(bigEndian(14))  // align
            body.append(slice.payload)
            offset += UInt32(slice.payload.count)
        }
        return header + body
    }

    private func write(_ data: Data, named name: String) throws -> URL {
        let file = root.appendingPathComponent(name)
        try data.write(to: file)
        return file
    }

    // MARK: - Tests

    func testAUniversalBinaryReportsEachSliceWithItsOwnDigest() throws {
        let arm = Data(repeating: 0xA1, count: 3_000)
        let intel = Data(repeating: 0xB2, count: 5_000)
        let file = try write(
            fatBinary([(Self.armCPU, arm), (Self.intelCPU, intel)]),
            named: "universal"
        )

        let slices = try SelfCheckSystemProbe.machOSlices(at: file)

        XCTAssertEqual(slices.map(\.architecture), ["arm64", "x86_64"])
        XCTAssertEqual(slices[0].sha256, digest(of: arm))
        XCTAssertEqual(slices[1].sha256, digest(of: intel))
    }

    /// The digest of a slice is the digest of that architecture on its own. That equivalence is the
    /// entire reason the pinned values in the build scripts still mean something after `lipo`.
    func testASliceDigestEqualsTheDigestOfThatArchitectureAlone() throws {
        let arm = Data((0..<4_096).map { UInt8($0 % 251) })
        let intel = Data((0..<8_192).map { UInt8($0 % 241) })
        let file = try write(
            fatBinary([(Self.armCPU, arm), (Self.intelCPU, intel)]),
            named: "equivalence"
        )

        let slices = try SelfCheckSystemProbe.machOSlices(at: file)

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: slices.map { ($0.architecture, $0.sha256) }),
            ["arm64": digest(of: arm), "x86_64": digest(of: intel)]
        )
    }

    func testASliceLargerThanOneReadChunkIsDigestedWhole() throws {
        // The walk reads in one-megabyte chunks; a slice that spans several must not stop early.
        let arm = Data(repeating: 0x5A, count: 3 * 1_024 * 1_024 + 17)
        let intel = Data(repeating: 0x6B, count: 1_024)
        let file = try write(fatBinary([(Self.armCPU, arm), (Self.intelCPU, intel)]), named: "big")

        let slices = try SelfCheckSystemProbe.machOSlices(at: file)

        XCTAssertEqual(slices.first?.sha256, digest(of: arm))
        XCTAssertEqual(slices.last?.sha256, digest(of: intel))
    }

    func testAThinBinaryReportsItselfAsOneSlice() throws {
        let body = Data(repeating: 0x33, count: 2_048)
        let bytes = thinBinary(cpu: Self.armCPU, body: body)
        let file = try write(bytes, named: "thin")

        let slices = try SelfCheckSystemProbe.machOSlices(at: file)

        XCTAssertEqual(slices.count, 1)
        XCTAssertEqual(slices.first?.architecture, "arm64")
        XCTAssertEqual(
            slices.first?.sha256,
            digest(of: bytes),
            "a thin file's slice is the whole file"
        )
    }

    /// One byte inside one slice. The file's own digest is not pinned anywhere, so this is exactly
    /// the case a whole-file check would wave through.
    func testAnAlteredByteDisturbsOnlyTheSliceItLandsIn() throws {
        let arm = Data(repeating: 0xA1, count: 3_000)
        let intel = Data(repeating: 0xB2, count: 5_000)
        var bytes = fatBinary([(Self.armCPU, arm), (Self.intelCPU, intel)])
        bytes[bytes.count - 1] ^= 0xFF
        let file = try write(bytes, named: "altered")

        let slices = try SelfCheckSystemProbe.machOSlices(at: file)

        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices[0].sha256, digest(of: arm), "the untouched slice is unchanged")
        XCTAssertNotEqual(slices[1].sha256, digest(of: intel))
    }

    func testAnArchitectureTheCheckerDoesNotKnowIsRefusedRatherThanGuessed() throws {
        let file = try write(
            fatBinary([(Self.armCPU, Data(repeating: 1, count: 8)), (0x0000_0012, Data(repeating: 2, count: 8))]),
            named: "unknown-arch"
        )

        XCTAssertTrue(
            try SelfCheckSystemProbe.machOSlices(at: file).isEmpty,
            "a slice of unknown architecture makes the whole answer unusable, not partial"
        )
    }

    func testFilesThatAreNotMachOReportNoSlices() throws {
        let text = try write(Data("this is not a Mach-O binary".utf8), named: "notes.txt")
        XCTAssertTrue(try SelfCheckSystemProbe.machOSlices(at: text).isEmpty)

        let empty = try write(Data(), named: "empty")
        XCTAssertTrue(try SelfCheckSystemProbe.machOSlices(at: empty).isEmpty)

        // A fat magic with nothing behind it: the header promises slices the file cannot supply.
        let truncated = try write(
            Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x02]),
            named: "truncated"
        )
        XCTAssertTrue(try SelfCheckSystemProbe.machOSlices(at: truncated).isEmpty)
    }

    func testAFatHeaderClaimingAnAbsurdNumberOfSlicesIsRefused() throws {
        var bytes = Data([0xCA, 0xFE, 0xBA, 0xBE])
        bytes.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        bytes.append(Data(repeating: 0, count: 4_096))
        let file = try write(bytes, named: "absurd")

        XCTAssertTrue(try SelfCheckSystemProbe.machOSlices(at: file).isEmpty)
    }

    /// A real universal binary from the system, to catch a walk that only works on fixtures.
    func testARealSystemUniversalBinaryIsReadRatherThanSkipped() throws {
        let slices = try SelfCheckSystemProbe.machOSlices(at: URL(fileURLWithPath: "/bin/echo"))

        XCTAssertGreaterThanOrEqual(slices.count, 2, "/bin/echo ships more than one architecture")
        XCTAssertEqual(Set(slices.map(\.sha256)).count, slices.count, "slices are distinct")
    }
}
