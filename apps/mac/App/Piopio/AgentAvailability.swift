import PiopioKit
import SwiftUI

/// Availability describes what can actually run, including the difference between window close and quit.
struct AgentAvailability: View {
    let engine: EngineController
    let summary: SessionSummary
    let hasMacTools: Bool
    @State private var expanded = false
    private var paused: Bool { summary.agent?.status?.paused == true }
    private var ready: Bool { engine.status == .ready }
    private var line: String {
        if !ready { return "Engine unavailable · schedules resume when connected" }
        if paused { return "Paused · scheduled runs are on hold" }
        if engine.runsInBackground { return "Runs while this Mac is awake · continues after Piopio quits" }
        return "Runs while this Mac is awake and Piopio is running"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: ready && !paused ? "desktopcomputer" : "pause.circle")
                    Text(line).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .font(.system(size: 12)).foregroundStyle(ready && !paused ? Color.dsFg2 : Color.dsAmber)
                .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(line + ". Availability details").accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                Text("Runs wait while this Mac is asleep or off. Closing the window keeps Piopio running; quitting requires background mode to keep schedules running.")
                if hasMacTools { Text("Mac app abilities require Piopio to remain open, the relevant macOS permissions, and any apps they use. The background engine alone cannot perform them.") }
                if let next = summary.agent?.status?.nextRun { Text("Next run: \(MainSidebar.when(next))") }
                Button("Background settings…") {
                    UserDefaults.standard.set("This Mac & cloud", forKey: "settingsSection")
                    WindowOpener.shared.openSettings?()
                }.buttonStyle(.link)
            }
        }
        .font(.system(size: 12)).foregroundStyle(Color.dsFg2)
        .padding(.horizontal, 24).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsChip)
    }
}
