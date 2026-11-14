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
        PaneTitle(title: "Browser", subtitle: "The browser in your conversations reads pages freely. The first time it would click or type on a site, it asks.")
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Sites")
            ListCard {
                if sites.isEmpty {
                    Row(title: "No sites yet", last: false) {
                        Text("“Allow, don't ask again” on a card adds a site here.").font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                        Spacer()
                    }
                }
                ForEach(sites, id: \.self) { s in
                    Row(title: s.site, last: false) {
                        Text(s.level == "allowed" ? "Always allowed" : "Blocked: never clicks or types here")
                            .font(.system(size: 12)).foregroundStyle(Color.dsFg3)
                        Spacer()
                        Button { Task { await set(s.site, "ask") } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(Color.dsFg3) }
                            .buttonStyle(.plain)
                            .help("Remove: acting here asks again")
                    }
                }
                Row(title: "Block a site", last: true) {
                    TextField("bank.example", text: $blocking)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                        .onSubmit { block() }
                    Button("Block") { block() }.disabled(blocking.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                }
            }
            Text("Passwords, one-time codes and card details are always yours to type, on every site.")
                .font(.system(size: 12)).foregroundStyle(Color.dsFg3).padding(.top, 4)
        }
        .padding(.bottom, 18)
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Browsing data")
            ListCard {
                Row(title: "Sign-ins and cookies", last: true) {
                    Text(cleared ? "Cleared." : "Kept on this Mac, for every conversation's browser. Not shared with Safari.")
                        .font(.system(size: 12)).foregroundStyle(Color.dsFg3).lineLimit(2)
                    Spacer()
                    Button("Clear…") { confirmClear = true }
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
        await BrowserCenter.shared.store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        cleared = true
    }
}
