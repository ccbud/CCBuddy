import SwiftUI

struct ElevatedCard: ViewModifier {
    var radius: CGFloat = 12
    var border: Color = .ccBorder
    func body(content: Content) -> some View {
        content
            .background(Color.ccElevated)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(border, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
    }
}
extension View {
    func elevatedCard(radius: CGFloat = 12, border: Color = .ccBorder) -> some View {
        modifier(ElevatedCard(radius: radius, border: border))
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
