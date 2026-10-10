import AppKit
import SwiftUI

private struct MeasuredScroll: Equatable {
    var offset: CGFloat
    var inset: CGFloat
    var height: CGFloat
}

private struct MeasuredSelectionKey: PreferenceKey {
    static var defaultValue: CGRect? { nil }

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = value ?? nextValue()
    }
}

@MainActor @Observable
private final class ScrollFixture {
    var intent = ScrollIntent(kind: .top)
    var selectedID = "row-0"
    var headerHeight: CGFloat
    var geometry = MeasuredScroll(offset: 0, inset: 0, height: 0)
    var selection: CGRect?

    init(headerHeight: CGFloat) { self.headerHeight = headerHeight }
}

private struct ScrollFixtureView: View {
    let fixture: ScrollFixture
    let scale: CGFloat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Text("Today").frame(height: 24 * scale)
                    ForEach((0..<100).map { "row-\($0)" }, id: \.self) { id in
                        Text(id)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 38 * scale)
                            .selectionFrame(id == fixture.selectedID)
                            .background {
                                if id == fixture.selectedID {
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: MeasuredSelectionKey.self,
                                            value: geometry.frame(in: .scrollView))
                                    }
                                }
                            }
                    }
                }
                .padding(.top, 4 * scale)
                .padding(.bottom, 8 * scale)
            }
            .scrollFollowsSelection(
                fixture.intent, row: fixture.selectedID,
                atOrigin: fixture.selectedID == "row-0", proxy: proxy)
            .onScrollGeometryChange(for: MeasuredScroll.self) {
                MeasuredScroll(
                    offset: $0.contentOffset.y, inset: $0.contentInsets.top,
                    height: $0.containerSize.height)
            } action: { _, geometry in fixture.geometry = geometry }
            .onPreferenceChange(MeasuredSelectionKey.self) { fixture.selection = $0 }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Text("Search").frame(height: fixture.headerHeight)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Text("Actions").frame(height: 52 * scale)
        }
        .onAppear { fixture.intent = ScrollIntent(kind: .top) }
    }
}

@main @MainActor
struct ScrollPositionTests {
    static var passes = 0
    static var failures = 0

    static func expect(_ message: String, until predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { pump() }
        pump()
        if predicate() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    static func exercise(width: CGFloat, scale: CGFloat) {
        let fixture = ScrollFixture(headerHeight: 54 * scale)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 475 * scale),
            styleMask: .borderless, backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: ScrollFixtureView(fixture: fixture, scale: scale))
        hosting.sizingOptions = []
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        expect("initial header remains below search (\(width), \(scale))") {
            fixture.geometry.inset > 0
                && abs(fixture.geometry.offset + fixture.geometry.inset) < 0.5
        }
        guard let scroll = scrollView(in: hosting) else {
            failures += 1
            print("FAIL: missing native scroll view")
            return
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 240))
        scroll.reflectScrolledClipView(scroll.contentView)
        expect("manual scrolling is not pulled back") { fixture.geometry.offset > 200 }

        fixture.intent = ScrollIntent(kind: .top)
        expect("reset restores the header and top padding") {
            abs(fixture.geometry.offset + fixture.geometry.inset) < 0.5
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 2400 * scale))
        scroll.reflectScrolledClipView(scroll.contentView)
        expect("manual scrolling can drop the selected row") { fixture.geometry.offset > 2000 }
        fixture.selection = nil
        fixture.selectedID = "row-1"
        fixture.intent = ScrollIntent(kind: .follow)
        expect("keyboard navigation reveals an unrealized row") {
            guard let frame = fixture.selection else { return false }
            return frame.minY >= -0.5 && frame.maxY <= fixture.geometry.height + 0.5
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 240))
        scroll.reflectScrolledClipView(scroll.contentView)
        expect("a settled selection releases manual scrolling") {
            abs(fixture.geometry.offset - 240) < 0.5
        }
        fixture.selectedID = "row-0"
        fixture.intent = ScrollIntent(kind: .follow)
        expect("following the first row also restores its section header") {
            abs(fixture.geometry.offset + fixture.geometry.inset) < 0.5
        }
        fixture.selectedID = "row-60"
        fixture.intent = ScrollIntent(kind: .center)
        expect("a later landing row is centered") {
            guard let frame = fixture.selection else { return false }
            return abs(frame.midY - fixture.geometry.height / 2) < 1
        }
        fixture.headerHeight += 12 * scale
        expect("a centered landing survives the header inset settling") {
            guard let frame = fixture.selection else { return false }
            return abs(frame.midY - fixture.geometry.height / 2) < 1
        }
        window.contentView = nil
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        exercise(width: 290, scale: 1)
        exercise(width: 750, scale: 1)
        exercise(width: 900, scale: 1.2)
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
