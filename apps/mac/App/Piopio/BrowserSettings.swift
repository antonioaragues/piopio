import PiopioKit
import SwiftUI
import WebKit

// Settings › Browser (docs/spec/22 §4.4, §7): the sites the model may always act on, the sites it never acts on, and
// your browsing data (the sign-ins the browser keeps).

private struct BrowserSitesResult: Decodable {
    struct Site: Decodable, Hashable { let site: String; let level: String }
    let sites: [Site]
}

private struct SetSiteParams: Encodable, Sendable {
    let site: String
    let level: String
}

struct BrowserSettingsPane: View {
    let engine: EngineController
    @State private var sites: [BrowserSitesResult.Site] = []
    @State private var blocking = ""
    @State private var confirmClear = false
    @State private var cleared = false

    var body: some View {
        SettingsHeader(title: "Browser", summary: "The browser in your conversations reads pages freely. The first time it would click or type on a site, it asks.")
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("Sites")
            ListCard {
                if sites.isEmpty {
                    SettingRow(title: "No sites yet", subtitle: "“Allow, don't ask again” on a card adds a site here.") { EmptyView() }
                }
                ForEach(sites, id: \.self) { s in
                    SettingRow(title: s.site, subtitle: s.level == "allowed" ? "Always allowed" : "Blocked: never clicks or types here") {
                        Button { Task { await set(s.site, "ask") } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(Color.dsFg3) }
                            .buttonStyle(.plain)
                            .help("Remove: acting here asks again")
                    }
                }
                SettingRow(title: "Block a site", last: true) {
                    TextField("bank.example", text: $blocking)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                        .onSubmit { block() }
                    Button("Block") { block() }.buttonStyle(PillStyle(compact: true)).disabled(blocking.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            FinePrint("Passwords, one-time codes and card details are always yours to type, on every site.").padding(.top, 12)
        }
        .padding(.bottom, 22)
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("Browsing data")
            ListCard {
                SettingRow(title: "Sign-ins and cookies", subtitle: cleared ? "Cleared." : "Kept on this Mac, for every conversation's browser. Not shared with Safari.", last: true) {
                    Button("Clear…") { confirmClear = true }.buttonStyle(PillStyle(compact: true))
                }
            }
        }
        .task { await load() }
        .confirmationDialog("Clear the browser's data?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { Task { await clear() } }
        } message: {
            Text("You'll be signed out of every site in Piopio's browser. Its cookies, storage and cache are deleted.")
        }
    }

    private func load() async {
        sites = (try? await engine.client?.call("browser.sites", Empty(), as: BrowserSitesResult.self))?.sites ?? []
    }

    private func set(_ site: String, _ level: String) async {
        _ = try? await engine.client?.call("browser.setSite", SetSiteParams(site: site, level: level), as: Empty.self)
        await load()
    }

    private func block() {
        let site = blocking.trimmingCharacters(in: .whitespaces).lowercased()
        guard !site.isEmpty else { return }
        blocking = ""
        Task { await set(browserSite(of: URL(string: site.contains("://") ? site : "https://\(site)")) ?? site, "blocked") }
    }

    private func clear() async {
        await Self.clearData()
        cleared = true
    }

    /// Every site's cookies, storage and cache in Piopio's browser (also Overview › Disk's "Clear browser data").
    static func clearData() async {
        await BrowserCenter.shared.store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}
