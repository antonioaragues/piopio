import AppKit
import PiopioTranscript
import SwiftUI

// The window's shell (docs/design/grey 9a, 10d): the traffic lights centered in a 52pt top bar, a sidebar that
// collapses, and the content toolbar every page shares.

/// The sidebar's collapsed state, for page toolbars: they leave room for the traffic lights and show the toggle.
struct SidebarControl: @unchecked Sendable {
    var collapsed = false
    var toggle: @MainActor () -> Void = {}
}

private struct SidebarControlKey: EnvironmentKey {
    static let defaultValue = SidebarControl()
}

extension EnvironmentValues {
    var sidebarControl: SidebarControl {
        get { self[SidebarControlKey.self] }
        set { self[SidebarControlKey.self] = newValue }
    }
}

/// The top bar's height, shared by the sidebar and every page toolbar.
enum Shell {
    static let barHeight: CGFloat = 52
    /// Where content starts when the sidebar is collapsed: past the traffic lights and the toggle.
    static let collapsedLeading: CGFloat = 112
}

/// The toggle in the top bar (sidebar.left, ⌃⌘S).
struct SidebarToggle: View {
    @Environment(\.sidebarControl) private var control

    var body: some View {
        Button { control.toggle() } label: { Image(systemName: "sidebar.left") }
            .buttonStyle(IconButtonStyle())
            .help(control.collapsed ? "Show the sidebar (⌃⌘S)" : "Hide the sidebar (⌃⌘S)")
            .accessibilityLabel(control.collapsed ? "Show sidebar" : "Hide sidebar")
    }
}

/// A page's toolbar (52): title 13.5 semibold and a 12 fg3 subtitle on one line, then icon-only ghost buttons on the
/// right. With the sidebar collapsed it starts after the traffic lights and the toggle.
struct PageHeader<Title: View, Actions: View>: View {
    @ViewBuilder var title: Title
    @ViewBuilder var actions: Actions
    @Environment(\.sidebarControl) private var control

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            title.lineLimit(1)
            Spacer(minLength: 12)
            actions
        }
        .padding(.leading, control.collapsed ? Shell.collapsedLeading : 20)
        .padding(.trailing, 12)
        .frame(height: Shell.barHeight)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }
}

extension PageHeader {
    /// The usual title: name, then a grey subtitle.
    init(_ name: String, subtitle: String = "", @ViewBuilder actions: () -> Actions) where Title == PageTitle {
        self.title = PageTitle(name: name, subtitle: subtitle)
        self.actions = actions()
    }
}

struct PageTitle: View {
    let name: String
    var subtitle = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.dsFg)
            if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(Color.dsFg3) }
        }
        .lineLimit(1)
    }
}

/// Moves the traffic lights so they sit centered in the 52pt top bar, 16pt from the left edge, and keeps them there
/// across resizes and full screen.
struct TrafficLightsPosition: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Anchor() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Anchor: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                    MainActor.assumeIsolated { if let window { Self.place(in: window) } }
                }
            }
            Self.place(in: window)
            DispatchQueue.main.async { [weak window] in if let window { Self.place(in: window) } }
        }

        override func layout() {
            super.layout()
            if let window { Self.place(in: window) }
        }

        static func place(in window: NSWindow) {
            guard !window.styleMask.contains(.fullScreen) else { return }
            let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (i, kind) in kinds.enumerated() {
                guard let button = window.standardWindowButton(kind), let bar = button.superview else { continue }
                let size = button.frame.size
                // The title bar view isn't flipped: y counts from its bottom edge.
                let y = bar.bounds.height - Shell.barHeight / 2 - size.height / 2
                button.setFrameOrigin(NSPoint(x: 16 + CGFloat(i) * 20, y: y))
            }
        }
    }
}
