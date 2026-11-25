import AppKit
import PiopioKit
import PiopioTranscript
import SwiftUI

/// A chat's Summary column, made of Build's blocks (docs/design/chat-summary, option B): **Tools** (web search, apps
/// and MCP servers, a switch each for this chat), **Skills**, and **Read** (docs/design/read: the files you gave it and
/// the pages it read). Context and cost are in the footer every
/// panel shares. The model is in the composer; what it's doing now is in the transcript.
struct ChatSummaryPanel: View {
    let engine: EngineController
    let thread: ThreadModel
    let summary: SessionSummary

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ToolsBlock(engine: engine, thread: thread, summary: summary, web: true).inspectorBlock()
                    SkillsBlock(thread: thread).inspectorBlock()
                    ReadBlock(thread: thread, cwd: nil).inspectorBlock(last: true)
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
            }
            InspectorFooter(thread: thread)
        }
    }
}
