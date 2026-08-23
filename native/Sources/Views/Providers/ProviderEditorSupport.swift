import AppKit
import SwiftUI

struct ProviderPreset: Identifiable {
    let id: String
    let title: String
    let name: String
    let baseURL: String
    let defaultModel: String
    let smallModel: String
    let wireProtocol: Provider.WireProtocol

    func apply(to provider: inout Provider) {
        provider.name = name
        provider.baseUrl = baseURL
        provider.defaultModel = defaultModel
        provider.smallFastModel = smallModel
        provider.protocol = wireProtocol
        provider.icon = nil
    }

    static let all: [ProviderPreset] = [
        .init(id: "glm", title: "GLM", name: "GLM", baseURL: "https://open.bigmodel.cn/api/anthropic/v1", defaultModel: "glm-5.2", smallModel: "glm-5.2", wireProtocol: .anthropic),
        .init(id: "deepseek", title: "DeepSeek", name: "DeepSeek", baseURL: "https://api.deepseek.com/anthropic", defaultModel: "deepseek-v4-pro", smallModel: "deepseek-v4-flash", wireProtocol: .anthropic),
        .init(id: "mimo", title: "MiMo", name: "MiMo", baseURL: "https://token-plan-sgp.xiaomimimo.com/anthropic", defaultModel: "mimo-v2.5-pro", smallModel: "mimo-v2.5", wireProtocol: .anthropic),
        .init(id: "kimi", title: "Kimi", name: "Kimi", baseURL: "https://api.kimi.com/coding", defaultModel: "kimi-for-coding", smallModel: "kimi-for-coding", wireProtocol: .anthropic),
        .init(id: "minimax", title: "MiniMax", name: "MiniMax", baseURL: "https://api.minimax.io/anthropic", defaultModel: "MiniMax-M3", smallModel: "MiniMax-M3", wireProtocol: .anthropic),
        .init(id: "nvidia", title: "NVIDIA", name: "NVIDIA", baseURL: "https://integrate.api.nvidia.com/v1", defaultModel: "z-ai/glm-5.2", smallModel: "z-ai/glm-5.2", wireProtocol: .openAIChat),
        .init(id: "google", title: "Google AI Studio", name: "Google AI Studio", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", defaultModel: "gemini-3.5-flash", smallModel: "gemini-3.1-flash-lite", wireProtocol: .openAIChat),
        .init(id: "openai", title: "OpenAI", name: "OpenAI", baseURL: "https://api.openai.com/v1", defaultModel: "gpt-5.2", smallModel: "gpt-5.2-mini", wireProtocol: .openAIResponses),
        .init(id: "openrouter", title: "OpenRouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", defaultModel: "", smallModel: "", wireProtocol: .openAIChat),
        .init(id: "custom", title: "自定义", name: "", baseURL: "", defaultModel: "", smallModel: "", wireProtocol: .anthropic),
    ]
}

enum ProviderEditorLayout {
    static let sheetSize = CGSize(width: 580, height: 654)
    static let presetSpacing: CGFloat = 6
    static let apiURLPlaceholder = "https://open.bigmodel.cn/api/anthropic/v1"
}

struct ProviderPresetFlowLayout: Layout {
    var horizontalSpacing = ProviderEditorLayout.presetSpacing
    var verticalSpacing = ProviderEditorLayout.presetSpacing

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? .greatestFiniteMagnitude
        let result = arrangement(maxWidth: proposedWidth, subviews: subviews)
        return CGSize(
            width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? result.size.width,
            height: result.size.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = arrangement(maxWidth: bounds.width, subviews: subviews)
        for placement in result.placements {
            subviews[placement.index].place(
                at: CGPoint(
                    x: bounds.minX + placement.origin.x,
                    y: bounds.minY + placement.origin.y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: placement.size.width,
                    height: placement.size.height
                )
            )
        }
    }

    private func arrangement(maxWidth: CGFloat, subviews: Subviews) -> Arrangement {
        var placements: [Placement] = []
        var cursor = CGPoint.zero
        var rowHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if cursor.x > 0, cursor.x + size.width > maxWidth {
                cursor.x = 0
                cursor.y += rowHeight + verticalSpacing
                rowHeight = 0
            }

            placements.append(.init(index: index, origin: cursor, size: size))
            measuredWidth = max(measuredWidth, cursor.x + size.width)
            rowHeight = max(rowHeight, size.height)
            cursor.x += size.width + horizontalSpacing
        }

        return Arrangement(
            size: CGSize(width: measuredWidth, height: cursor.y + rowHeight),
            placements: placements
        )
    }

    private struct Arrangement {
        let size: CGSize
        let placements: [Placement]
    }

    private struct Placement {
        let index: Int
        let origin: CGPoint
        let size: CGSize
    }
}

struct ProviderIconView: View {
    let name: String
    let icon: String?
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let image = embeddedImage {
                Image(nsImage: image).resizable().scaledToFill()
            } else if let remoteURL {
                AsyncImage(url: remoteURL) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { fallback }
                }
            } else if let brandImage {
                Image(nsImage: brandImage).resizable().scaledToFit()
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        .clipped()
        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        Text(customEmoji ?? Self.emojis[Self.legacyHue(for: name) % Self.emojis.count])
            .font(.system(size: size * 0.46))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var background: some View {
        let hue = Double(Self.legacyHue(for: name)) / 360
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.62, brightness: 0.82),
                Color(hue: (hue + 0.125).truncatingRemainder(dividingBy: 1), saturation: 0.68, brightness: 0.67),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var embeddedImage: NSImage? {
        guard let icon, icon.hasPrefix("data:"),
              let comma = icon.firstIndex(of: ","),
              icon[..<comma].contains(";base64"),
              let data = Data(base64Encoded: String(icon[icon.index(after: comma)...]))
        else { return nil }
        return NSImage(data: data)
    }

    private var remoteURL: URL? {
        guard let icon, icon.hasPrefix("https://") || icon.hasPrefix("http://") else { return nil }
        return URL(string: icon)
    }

    private var customEmoji: String? {
        guard let icon, !icon.isEmpty, !icon.contains("://"), !icon.hasPrefix("data:") else {
            return nil
        }
        return icon
    }

    private var brandImage: NSImage? {
        let lower = name.lowercased()
        let resource: (String, String)?
        if ["google ai studio", "gemini", "generativelanguage"].contains(where: lower.contains) {
            resource = ("google-ai-studio", "png")
        } else if lower.contains("kimi") || lower.contains("moonshot") {
            resource = ("kimi", "svg")
        } else if lower.contains("deepseek") {
            resource = ("deepseek", "svg")
        } else if lower.contains("glm") || lower.contains("bigmodel") || lower.contains("智谱") {
            resource = ("zhipu", "svg")
        } else if lower.contains("mimo") || lower.contains("xiaomi") || lower.contains("小米") {
            resource = ("xiaomi", "svg")
        } else if lower.contains("minimax") || lower.contains("mini max") {
            resource = ("minimax", "svg")
        } else if lower.contains("nvidia") {
            resource = ("nvidia", "svg")
        } else {
            resource = nil
        }
        guard let resource,
              let url = Bundle.main.url(forResource: resource.0, withExtension: resource.1)
        else { return nil }
        return NSImage(contentsOf: url)
    }

    static let emojis = [
        "🤖", "🧠", "⚡", "🚀", "🦊", "🐳", "🌟", "💎", "🔮", "🎯", "🛰️", "🧩",
        "🔆", "🌀", "🦁", "🐲", "🦄", "🍀", "🔥", "❄️", "🌈", "🎨", "🧪", "📡",
        "🛡️", "🎲", "🌶️", "🦉", "🐙", "🪐", "✨", "🌊",
    ]

    /// Mirrors the legacy renderer's `hashHue` exactly. JavaScript's `charCodeAt` iterates UTF-16
    /// code units, and reduces after every character, so custom-provider icons stay stable across
    /// the native migration (including names outside ASCII).
    static func legacyHue(for value: String) -> Int {
        var hash = 0
        for codeUnit in value.utf16 {
            hash = (hash * 31 + Int(codeUnit)) % 360
        }
        return hash
    }
}

enum ProviderIconEncoder {
    static func dataURL(from file: URL, size: Int = 72) throws -> String {
        guard let image = NSImage(contentsOf: file),
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw CocoaError(.fileReadCorruptFile) }
        let sourceSize = CGSize(width: source.width, height: source.height)
        let scale = max(CGFloat(size) / sourceSize.width, CGFloat(size) / sourceSize.height)
        let target = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(
            x: (CGFloat(size) - target.width) / 2,
            y: (CGFloat(size) - target.height) / 2,
            width: target.width,
            height: target.height
        ))
        guard let output = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }
}
