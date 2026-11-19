import PiopioTranscript
import SwiftUI
import WebKit

/// A conversation's Browser panel (docs/spec/22 §5): its tabs, back / forward / reload, the address, and the page,
/// which you can use too. It opens by itself the first time the model browses in the conversation.
struct BrowserPanel: View {
    let refID: String
    /// Stops the conversation's turn (the bar's Stop): the model stops browsing and you have the page.
    var onStop: (() -> Void)?
    /// Closes the panel (the toolbar's ×).
    var onClose: (() -> Void)?
    @State private var address = ""

    var body: some View {
        let session = BrowserCenter.shared.session(refID)
        VStack(spacing: 0) {
            if session.tabs.count > 1 { tabStrip(session) }
            toolbar(session)
            drivingBar(session)
            if let tab = session.current {
                // The page inset in the Browser's card (docs/design/card-layout F4): radius 7 and a hairline.
                BrowserWebView(tab: tab).id(ObjectIdentifier(tab))
                    .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(nsColor: DS.cardEdge), lineWidth: 1).allowsHitTesting(false) }
                    .padding([.horizontal, .bottom], 8)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "globe").font(.system(size: 22)).foregroundStyle(Color.dsFg3)
                    Text("Type an address, or ask in the chat to open a page.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            }
        }
        .onChange(of: session.current?.url) { _, url in address = url?.absoluteString ?? "" }
        .onAppear { address = session.current?.url?.absoluteString ?? "" }
    }

    /// "Piopio is browsing" while the model clicks and types here, and a few seconds after (spec 22 §5).
    private func drivingBar(_ session: BrowserSession) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if session.acting || session.lastActed.map({ context.date.timeIntervalSince($0) < 6 }) == true {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Piopio is browsing").font(.system(size: 12, weight: .medium))
                    Spacer()
                    if let onStop {
                        Button("Stop") { onStop() }
                            .controlSize(.small)
                            .help("Stop the model here; the page stays as it is, for you")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.10))
            }
        }
    }

    private func tabStrip(_ session: BrowserSession) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(session.tabs, id: \.id) { tab in
                    HStack(spacing: 4) {
                        Text(tab.title.isEmpty ? (tab.url?.host() ?? "New tab") : tab.title)
                            .font(.system(size: 11)).lineLimit(1).frame(maxWidth: 140, alignment: .leading)
                        Button { session.closeTab(tab) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)) }
                            .buttonStyle(.plain).foregroundStyle(Color.dsFg3).help("Close this tab")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(session.current === tab ? Color.dsChip : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { session.current = tab }
                }
            }
            .padding(.horizontal, 8).padding(.top, 8)
        }
    }

    private func toolbar(_ session: BrowserSession) -> some View {
        let tab = session.current
        return HStack(spacing: 4) {
            Button { tab?.view.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(IconButtonStyle()).disabled(!(tab?.canGoBack ?? false)).help("Back")
            Button { tab?.view.goForward() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(IconButtonStyle()).disabled(!(tab?.canGoForward ?? false)).help("Forward")
            Button { if tab?.isLoading == true { tab?.view.stopLoading() } else { tab?.view.reload() } } label: {
                Image(systemName: tab?.isLoading == true ? "xmark" : "arrow.clockwise")
            }
            .buttonStyle(IconButtonStyle()).disabled(tab == nil).help(tab?.isLoading == true ? "Stop loading" : "Reload")
            HStack(spacing: 7) {
                Image(systemName: tab?.url?.scheme == "https" ? "lock" : "globe").font(.system(size: 10)).foregroundStyle(Color.dsFg3)
                TextField("Address or search", text: $address)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onSubmit { session.go(address) }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color.dsCardField, in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
            .padding(.horizontal, 4)
            Button { session.newTab() } label: { Image(systemName: "plus") }
                .buttonStyle(IconButtonStyle()).help("New tab")
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 12)) }
                    .buttonStyle(IconButtonStyle()).help("Close the browser").accessibilityLabel("Close browser")
            }
        }
        .padding(.leading, 10).padding(.trailing, 8)
        .frame(height: 48)
    }
}

/// Shows a tab's web view; when the panel goes away, the view goes back to the browser's transparent window and keeps
/// its page.
private struct BrowserWebView: NSViewRepresentable {
    let tab: BrowserTab

    func makeCoordinator() -> Coordinator { Coordinator(tab: tab) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 7
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        attach(tab.view, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if tab.view.superview !== container { attach(tab.view, to: container) }
        context.coordinator.tab = tab
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        let view = coordinator.tab.view
        if view.superview === container { MainActor.assumeIsolated { BrowserCenter.shared.park(view) } }
    }

    private func attach(_ view: WKWebView, to container: NSView) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    final class Coordinator {
        var tab: BrowserTab
        init(tab: BrowserTab) { self.tab = tab }
    }
}
