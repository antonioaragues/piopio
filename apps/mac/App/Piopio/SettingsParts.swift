import PiopioKit
import SwiftUI

// The list-page pattern every Settings page shares (design handoff "Settings › Connectors, Chat, MCP servers,
// Extensions, This Mac & cloud", after Models): a header with a one-line summary and one add button, cards that show
// only what you have, rows that push a detail page, adding in a sheet, editing on the detail page.

/// Title (20 bold), one line of facts (13.5 fg2), and the page's actions top-right.
struct SettingsHeader<Actions: View>: View {
    let title: String
    let summary: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 20, weight: .bold)).tracking(-0.3)
                Text(summary).font(.system(size: 13)).foregroundStyle(Color.dsFg2)
            }
            Spacer()
            HStack(spacing: 8) { actions }
        }
        .padding(.bottom, 20)
    }
}

extension SettingsHeader where Actions == EmptyView {
    init(title: String, summary: String) { self.init(title: title, summary: summary) { EmptyView() } }
}

/// "+ Add …": the page's one primary button (inv capsule), always in the same place.
struct AddButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).font(.system(size: 13)).foregroundStyle(Color.accentColor) }
            .buttonStyle(.plain)
    }
}

/// A card's title (13 semibold) with an optional trailing link or note.
struct CardTitle<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 12.5)).foregroundStyle(Color.dsFg3) }
            Spacer()
            trailing
        }
        .padding(.bottom, 7)
    }
}

extension CardTitle where Trailing == EmptyView {
    init(_ title: String, detail: String? = nil) { self.init(title: title, detail: detail) { EmptyView() } }
}

/// The hairline between rows; inset to the text when rows have a tile.
struct RowDivider: View {
    var inset: CGFloat = 62
    var body: some View { Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.leading, inset) }
}

/// Fine print (12 fg3) under or beside what it's about.
struct FinePrint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 12)).foregroundStyle(Color.dsFg3).fixedSize(horizontal: false, vertical: true) }
}

/// A small capsule badge: where something is used, a version, "Soon".
struct SettingsBadge: View {
    let text: String
    var tint: Color?
    init(_ text: String, tint: Color? = nil) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Color.dsFg3)
    }
}

/// A tile with letters on a color (servers, packages, apps without a symbol).
struct LetterTile: View {
    let text: String
    var color: Color
    var size: CGFloat = 34
    var body: some View {
        Text(text).font(.system(size: size * 0.33, weight: .semibold)).foregroundStyle(Color.dsFg2)
            .frame(width: size, height: size)
            .background(Color.dsChip, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }

    /// "playwright" → "PW", "@mario/pi-review" → "PR".
    static func initials(_ name: String) -> String {
        let base = name.split(separator: "/").last.map(String.init) ?? name
        let words = base.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2 { return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
        return String(base.filter { $0.isLetter || $0.isNumber }.prefix(2)).uppercased()
    }
}

/// One row of a list page: 34pt tile, name, status dot, subtitle, optional badge, chevron. The whole row opens its page.
struct SettingsListRow<Tile: View, Subtitle: View, Trailing: View>: View {
    let name: String
    var dot: Color?
    var highlighted = false
    let open: () -> Void
    @ViewBuilder var tile: Tile
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                tile
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name).font(.system(size: 13)).foregroundStyle(Color.dsFg).lineLimit(1)
                        if dot != nil { Circle().strokeBorder(Color.dsFg3, lineWidth: 1).frame(width: 6, height: 6) }
                    }
                    subtitle.font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(1)
                }
                Spacer(minLength: 12)
                trailing
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.dsFg3)
            }
            .padding(.horizontal, 14).frame(minHeight: 50)
            .background(highlighted ? Color.dsAccentSoft : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }
}

/// A detail page pushed inside Settings: back link, 48pt tile header with a status line, cards, and a footer with what
/// removing it does and the remove button.
struct SettingsDetail<Tile: View, Status: View, Actions: View, Content: View>: View {
    let back: String
    let title: String
    let goBack: () -> Void
    var footer: String?
    var remove: String?
    var onRemove: () -> Void = {}
    @ViewBuilder var tile: Tile
    @ViewBuilder var status: Status
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: goBack) { Label(back, systemImage: "chevron.left").font(.system(size: 12.5)) }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor).padding(.bottom, 14)
            HStack(spacing: 14) {
                tile
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 20, weight: .bold)).lineLimit(1)
                    status.font(.system(size: 12.5)).foregroundStyle(Color.dsFg2).lineLimit(1)
                }
                Spacer()
                HStack(spacing: 8) { actions }
            }
            .padding(.bottom, 18)
            VStack(alignment: .leading, spacing: 20) { content }
            if footer != nil || remove != nil {
                Rectangle().fill(Color.dsLine).frame(height: 0.5).padding(.top, 22)
                HStack(alignment: .center) {
                    if let footer { FinePrint(footer) }
                    Spacer(minLength: 12)
                    if let remove {
                        Button(action: onRemove) { Text(remove).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.dsRed) }
                            .buttonStyle(PillStyle(compact: true))
                    }
                }
                .padding(.top, 12)
            }
        }
    }
}

/// "● Running": a status dot and its words.
struct StatusText: View {
    let color: Color
    let text: String
    var body: some View {
        Text(text)
    }
}

/// The empty state of a list page: a title, one sentence, then real starting points.
struct SettingsEmpty<Content: View>: View {
    let title: String
    let message: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.system(size: 20, weight: .bold)).padding(.top, 40)
            Text(message).font(.system(size: 13.5)).foregroundStyle(Color.dsFg2).multilineTextAlignment(.center).frame(maxWidth: 440).padding(.top, 6)
            VStack(spacing: 10) { content }.frame(maxWidth: 460).padding(.top, 22)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Something found on this Mac or in another app, in a hairline box.
struct FoundCard<Actions: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Color.dsFg2).lineLimit(1)
            }
            Spacer()
            actions
        }
        .padding(.horizontal, 14).frame(minHeight: 56)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 0.5))
    }
}

/// Runs / Asks first / Off for a connector's capability (c2, c4), with its colored dot.
struct PermissionMenu: View {
    let permission: ConnectorPermission
    var choices: [ConnectorPermission] = ConnectorPermission.allCases
    let set: (ConnectorPermission) -> Void

    static func title(_ p: ConnectorPermission) -> String {
        switch p {
        case .runs: "Runs"
        case .ask: "Asks first"
        case .off: "Off"
        }
    }

    static func color(_ p: ConnectorPermission) -> Color {
        switch p {
        case .runs: .dsFg2
        case .ask: .dsFg3
        case .off: .dsFg3
        }
    }

    var body: some View {
        Menu {
            ForEach(choices, id: \.self) { p in
                Button { set(p) } label: {
                    if p == permission { Label(Self.title(p), systemImage: "checkmark") } else { Text(Self.title(p)) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(Self.color(permission)).frame(width: 6, height: 6)
                Text(Self.title(permission)).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dsFg)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.dsFg3)
            }
            .padding(.horizontal, 9).frame(height: 24)
            .background(Color.dsChip, in: Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// A row with a label and a subtitle on the left and a toggle on the right (settings cards).
struct ToggleRow: View {
    let title: String
    var subtitle: String?
    var subtitleColor: Color = .dsFg3
    var last = false
    @Binding var isOn: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    if let subtitle { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(subtitleColor) }
                }
                Spacer()
                Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            .padding(.horizontal, 14).frame(minHeight: 46)
            if !last { RowDivider(inset: 14) }
        }
    }
}
