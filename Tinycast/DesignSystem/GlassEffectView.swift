import SwiftUI

struct GlassEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            return NSGlassEffectView()
        }
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Fork: glass on macOS 26, the AppKit backdrop above on macOS 15.
private struct PanelGlassBackdrop: ViewModifier {
    let isCollapsed: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.background {
                Color.clear.glassEffect(isCollapsed ? .identity : .regular, in: Rectangle())
            }
        } else {
            content.background { if !isCollapsed { GlassEffectView() } }
        }
    }
}

extension View {
    func panelGlassBackdrop(isCollapsed: Bool) -> some View {
        modifier(PanelGlassBackdrop(isCollapsed: isCollapsed))
    }
}
