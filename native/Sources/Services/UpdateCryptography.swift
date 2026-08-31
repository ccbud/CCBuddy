import CryptoKit
import Foundation

protocol UpdateArtifactVerifying: Sendable {
    func verify(
        artifact: Data,
        encodedSignature: String,
        expectedSHA256: String?
    ) throws -> String
}

struct SignedUpdateArtifactVerifier: UpdateArtifactVerifying {
    static let tauriPublicKey = "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IEZCMTMwRjI5MDhCNjE1NzUKUldSMUZiWUlLUThUK3kybFBUU3ljMWUyenAwR3U1NjdPZm1jM25ocndIclhLYUFGTU92KzJXRFQK"

    private let minisign: MinisignUpdateVerifier

    init(encodedPublicKey: String = Self.tauriPublicKey) throws {
        minisign = try MinisignUpdateVerifier(encodedPublicKey: encodedPublicKey)
    }

    func verify(
        artifact: Data,
        encodedSignature: String,
        expectedSHA256: String?
    ) throws -> String {
        guard minisign.verify(artifact: artifact, encodedSignature: encodedSignature) else {
            throw UpdateServiceError.invalidSignature
        }
        let actual = SHA256.hash(data: artifact).map { String(format: "%02x", $0) }.joined()
        if let expectedSHA256 {
            let normalized = expectedSHA256
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "sha256:", with: "")
            guard normalized.count == 64,
                  normalized.allSatisfy({ $0.isHexDigit }),
                  normalized == actual
            else { throw UpdateServiceError.digestMismatch }
        }
        return actual
    }
}

struct MinisignUpdateVerifier: Sendable {
    private let keyID: Data
    private let publicKey: Curve25519.Signing.PublicKey

    init(encodedPublicKey: String) throws {
        let decodedText: String
        if encodedPublicKey.contains("minisign public key") {
            decodedText = encodedPublicKey
        } else if let outer = Data(base64Encoded: encodedPublicKey),
                  let text = String(data: outer, encoding: .utf8),
                  text.contains("minisign public key") {
            decodedText = text
        } else {
            decodedText = encodedPublicKey
        }
        let lines = decodedText.split(whereSeparator: \.isNewline).map(String.init)
        let encodedBinary = lines.count >= 2 ? lines[1] : lines.first ?? ""
        guard let binary = Data(base64Encoded: encodedBinary), binary.count == 42 else {
            throw UpdateServiceError.invalidSignature
        }
        let algorithm = binary.prefix(2)
        guard algorithm == Data([0x45, 0x64]) || algorithm == Data([0x45, 0x44]) else {
            throw UpdateServiceError.invalidSignature
        }
        keyID = binary.subdata(in: 2..<10)
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: binary.subdata(in: 10..<42))
        } catch {
            throw UpdateServiceError.invalidSignature
        }
    }

    func verify(artifact: Data, encodedSignature: String) -> Bool {
        guard encodedSignature.utf8.count <= 16 * 1_024,
              let outer = Data(base64Encoded: encodedSignature),
              let signatureText = String(data: outer, encoding: .utf8)
        else { return false }
        return verify(artifact: artifact, signatureText: signatureText)
    }

    func verify(artifact: Data, signatureText: String) -> Bool {
        let lines = signatureText.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count == 4,
              lines[0].hasPrefix("untrusted comment: "),
              lines[2].hasPrefix("trusted comment: "),
              let signatureEnvelope = Data(base64Encoded: lines[1]),
              signatureEnvelope.count == 74,
              signatureEnvelope.prefix(2) == Data([0x45, 0x44]),
              signatureEnvelope.subdata(in: 2..<10) == keyID,
              let globalSignature = Data(base64Encoded: lines[3]), globalSignature.count == 64
        else { return false }

        let signature = signatureEnvelope.subdata(in: 10..<74)
        let digest = Blake2b512.hash(artifact)
        guard publicKey.isValidSignature(signature, for: digest) else { return false }

        let trustedComment = String(lines[2].dropFirst("trusted comment: ".count))
        var globalPayload = signature
        globalPayload.append(Data(trustedComment.utf8))
        return publicKey.isValidSignature(globalSignature, for: globalPayload)
    }
}

enum Blake2b512 {
    private static let initializationVector: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    ]
    private static let permutations: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    ]

    static func hash(_ data: Data) -> Data {
        data.withUnsafeBytes { rawBuffer in
            hash(rawBuffer.bindMemory(to: UInt8.self))
        }
    }

    private static func hash(_ bytes: UnsafeBufferPointer<UInt8>) -> Data {
        var state = initializationVector
        state[0] ^= 0x0101_0000 ^ 64
        var offset = 0
        var counterLow: UInt64 = 0
        var counterHigh: UInt64 = 0

        while bytes.count - offset > 128 {
            let block = Array(bytes[offset..<(offset + 128)])
            add(128, low: &counterLow, high: &counterHigh)
            compress(block, state: &state, low: counterLow, high: counterHigh, final: false)
            offset += 128
        }

        let remaining = bytes.count - offset
        var finalBlock = [UInt8](repeating: 0, count: 128)
        if remaining > 0 { finalBlock.replaceSubrange(0..<remaining, with: bytes[offset...]) }
        add(UInt64(remaining), low: &counterLow, high: &counterHigh)
        compress(finalBlock, state: &state, low: counterLow, high: counterHigh, final: true)

        var result = Data(capacity: 64)
        for word in state {
            var littleEndian = word.littleEndian
            withUnsafeBytes(of: &littleEndian) { result.append(contentsOf: $0) }
        }
        return result
    }

    private static func add(_ amount: UInt64, low: inout UInt64, high: inout UInt64) {
        let previous = low
        low &+= amount
        if low < previous { high &+= 1 }
    }

    private static func compress(
        _ block: [UInt8],
        state: inout [UInt64],
        low: UInt64,
        high: UInt64,
        final: Bool
    ) {
        var message = [UInt64](repeating: 0, count: 16)
        for index in 0..<16 {
            let start = index * 8
            var value: UInt64 = 0
            for byte in 0..<8 { value |= UInt64(block[start + byte]) << UInt64(byte * 8) }
            message[index] = value
        }
        var working = state + initializationVector
        working[12] ^= low
        working[13] ^= high
        if final { working[14] = ~working[14] }

        for permutation in permutations {
            mix(&working, 0, 4, 8, 12, message[permutation[0]], message[permutation[1]])
            mix(&working, 1, 5, 9, 13, message[permutation[2]], message[permutation[3]])
            mix(&working, 2, 6, 10, 14, message[permutation[4]], message[permutation[5]])
            mix(&working, 3, 7, 11, 15, message[permutation[6]], message[permutation[7]])
            mix(&working, 0, 5, 10, 15, message[permutation[8]], message[permutation[9]])
            mix(&working, 1, 6, 11, 12, message[permutation[10]], message[permutation[11]])
            mix(&working, 2, 7, 8, 13, message[permutation[12]], message[permutation[13]])
            mix(&working, 3, 4, 9, 14, message[permutation[14]], message[permutation[15]])
        }
        for index in 0..<8 { state[index] ^= working[index] ^ working[index + 8] }
    }

    private static func mix(
        _ values: inout [UInt64],
        _ a: Int, _ b: Int, _ c: Int, _ d: Int,
        _ first: UInt64, _ second: UInt64
    ) {
        values[a] = values[a] &+ values[b] &+ first
        values[d] = (values[d] ^ values[a]).rotatedRight(32)
        values[c] = values[c] &+ values[d]
        values[b] = (values[b] ^ values[c]).rotatedRight(24)
        values[a] = values[a] &+ values[b] &+ second
        values[d] = (values[d] ^ values[a]).rotatedRight(16)
        values[c] = values[c] &+ values[d]
        values[b] = (values[b] ^ values[c]).rotatedRight(63)
    }
}

private extension UInt64 {
    func rotatedRight(_ count: UInt64) -> UInt64 { (self >> count) | (self << (64 - count)) }
}
