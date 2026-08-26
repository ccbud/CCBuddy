import SwiftUI

// MARK: - Surfaces

/// A flat reading/content surface. Persistent interface never casts a shadow, so separation comes
/// from the tone step alone; the hairline is only drawn when the surface sits on the same tone.
struct PanelSurface: ViewModifier {
    var radius: CGFloat = Radius.panel
    var bordered: Bool = false

    func body(content: Content) -> some View {
        content
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if bordered {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: 1)
                }
            }
    }
}

/// A transient overlay — menu, sheet, command palette, toast. These are the only surfaces allowed
/// to cast a shadow.
struct FloatingSurface: ViewModifier {
    var radius: CGFloat = Radius.panel

    func body(content: Content) -> some View {
        content
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
    }
}

extension View {
    func panelSurface(radius: CGFloat = Radius.panel, bordered: Bool = false) -> some View {
        modifier(PanelSurface(radius: radius, bordered: bordered))
    }

    func floatingSurface(radius: CGFloat = Radius.panel) -> some View {
        modifier(FloatingSurface(radius: radius))
    }

    /// A one-pixel rule pinned to an edge, used instead of a full border between same-tone areas.
    func hairline(_ edge: VerticalAlignment = .bottom) -> some View {
        overlay(alignment: edge == .top ? .top : .bottom) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }
}

/// The standard inset for a destination's scrolling content.
///
/// Every page had been repeating these numbers, which is how one of them ended up with none at all:
/// content flush against the header's hairline and against the window edge. `measure` caps the
/// reading width on a wide window without letting the block drift away from the leading edge on a
/// narrow one.
struct PageContent: ViewModifier {
    var measure: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.xl)
            .padding(.bottom, Space.xxl)
            .frame(maxWidth: measure, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

extension View {
    func pageContent(measure: CGFloat = 920) -> some View {
        modifier(PageContent(measure: measure))
    }
}

// MARK: - Accessibility

extension View {
    /// Names a whole destination for automation without stealing its contents' identities.
    ///
    /// SwiftUI propagates an identifier placed on a container down into its descendants, where it
    /// replaces their own, more specific hooks — a destination marked this way answered to
    /// `view.providers` for its hero, its buttons and its scroll view alike. A one-point marker
    /// carries the container's name instead, and nothing inherits it.
    func accessibilityContainerIdentifier(_ identifier: String, label: String) -> some View {
        overlay(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Buttons

/// The four button roles. Anything that needs a fifth is a design question, not a code question.
enum CCButtonRole {
    /// Clay fill. One per view, reserved for the single most likely next action.
    case primary
    /// Quiet fill with a hairline. The default for ordinary actions.
    case secondary
    /// Transparent until hover. For toolbar and row-level affordances.
    case quiet
    /// Destructive confirmation inside dialogs and menus.
    case danger
}

struct CCButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var role: CCButtonRole = .secondary
    var size: CGFloat = Metrics.controlHeight
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ccBody(role == .primary ? .semibold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, Space.md)
            .frame(minHeight: size)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(background(pressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .overlay {
                if role == .secondary {
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch role {
        case .primary: Theme.onAccent
        case .secondary: Theme.foreground
        case .quiet: Theme.mutedForeground
        case .danger: Theme.danger
        }
    }

    private func background(pressed: Bool) -> Color {
        switch role {
        case .primary: pressed ? Theme.accentText : Theme.accent
        case .secondary: pressed ? Theme.hover : Theme.fillSubtle
        case .quiet: pressed ? Theme.hover : .clear
        case .danger: pressed ? Theme.dangerSoft : Theme.dangerSoft.opacity(0.6)
        }
    }
}

extension ButtonStyle where Self == CCButtonStyle {
    static var ccPrimary: CCButtonStyle { CCButtonStyle(role: .primary) }
    static var ccSecondary: CCButtonStyle { CCButtonStyle(role: .secondary) }
    static var ccQuiet: CCButtonStyle { CCButtonStyle(role: .quiet) }
    static var ccDanger: CCButtonStyle { CCButtonStyle(role: .danger) }
}

/// A square, icon-only control for toolbars and row affordances. Transparent at rest so it never
/// competes with the selected row underneath it.
struct CCIconButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var size: CGFloat = Metrics.controlHeight
    var symbolSize: CGFloat = Typography.caption
    var tint: Color = Theme.mutedForeground
    var filled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: symbolSize, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                configuration.isPressed
                    ? Theme.hover
                    : (filled ? Theme.fillSubtle : Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == CCIconButtonStyle {
    static var ccIcon: CCIconButtonStyle { CCIconButtonStyle() }
}

// MARK: - Small primitives

/// A count or status pill. Label step, muted, tight radius — never colored for decoration.
struct CCBadge: View {
    let text: String
    var tint: Color = Theme.mutedForeground
    var backing: Color = Theme.fill

    var body: some View {
        Text(text)
            .font(.ccLabel(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, Space.xs + 1)
            .padding(.vertical, 1)
            .background(backing)
            .clipShape(RoundedRectangle(cornerRadius: Radius.badge, style: .continuous))
            .lineLimit(1)
    }
}

/// A keyboard hint such as ⌘K.
struct CCKeyBadge: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.ccLabel(.medium))
            .foregroundStyle(Theme.mutedForeground)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.fill)
            .clipShape(RoundedRectangle(cornerRadius: Radius.keyboard, style: .continuous))
            .fixedSize()
    }
}

/// A status dot paired with its own label, so state never depends on color alone.
struct CCStatusLabel: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: Space.xs + 1) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text).font(.ccLabel(.medium)).foregroundStyle(tint).lineLimit(1)
        }
    }
}

/// Section head above a group of rows or fields.
struct CCSectionHeader: View {
    let title: String
    var trailing: AnyView?

    init(_ title: String) {
        self.title = title
        self.trailing = nil
    }

    init<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(title)
                .font(.ccBody(.medium))
                .foregroundStyle(Theme.foreground)
            Spacer(minLength: Space.sm)
            trailing
        }
    }
}

/// The shared empty/undetermined state. One icon disc, one stated title, at most one sentence of
/// help that names a concrete next action.
struct CCEmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    var message: String?
    var showsProgress: Bool = false
    var compact: Bool = false
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Space.md) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else {
                ZStack {
                    Circle().fill(Theme.fill)
                    Image(systemName: symbol)
                        .font(.system(size: compact ? 20 : 24, weight: .light))
                        .foregroundStyle(Theme.mutedForeground)
                }
                .frame(width: compact ? 48 : 58, height: compact ? 48 : 58)
            }
            VStack(spacing: Space.xs + 2) {
                Text(title)
                    .font(.ccHeading())
                    .foregroundStyle(Theme.foreground)
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.ccCaption())
                        .foregroundStyle(Theme.mutedForeground)
                        .multilineTextAlignment(.center)
                }
            }
            actions
        }
        .padding(compact ? Space.xl : Space.xxl)
        .frame(maxWidth: compact ? 320 : 360)
    }
}

extension CCEmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String? = nil, showsProgress: Bool = false, compact: Bool = false) {
        self.init(
            symbol: symbol,
            title: title,
            message: message,
            showsProgress: showsProgress,
            compact: compact,
            actions: { EmptyView() }
        )
    }
}

// MARK: - Legacy shims

/// Retained so unmigrated views keep compiling. The shadow is gone: persistent surfaces are flat.
struct ElevatedCard: ViewModifier {
    var radius: CGFloat = Radius.panel
    var border: Color = Theme.separator

    func body(content: Content) -> some View {
        content
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            }
    }
}

extension View {
    func elevatedCard(radius: CGFloat = Radius.panel, border: Color = Theme.separator) -> some View {
        modifier(ElevatedCard(radius: radius, border: border))
    }
}

struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
