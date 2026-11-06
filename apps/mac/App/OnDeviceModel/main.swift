import Foundation
import FoundationModels

// piopio-fm: Apple's on-device model (Foundation Models) for the engine's utility work (docs/spec/07-shared §1.3):
// titles, summaries, commit messages, learned facts. The engine runs it as a child process, with or without the app
// open, so nothing in these tasks leaves the Mac.
//
//   piopio-fm --status            → {"available": true} or {"available": false, "reason": "…"}
//   piopio-fm < {"instructions", "prompt"}  → {"text": "…"} or {"error": "…", "unavailable": true?}

struct Request: Decodable { var instructions: String; var prompt: String }

func reply(_ object: [String: Any]) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{\"error\":\"encoding\"}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(object["error"] == nil ? 0 : 1)
}

func unavailableReason(_ availability: SystemLanguageModel.Availability) -> String? {
    switch availability {
    case .available: return nil
    case .unavailable(.deviceNotEligible): return "This Mac can't run Apple Intelligence."
    case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is off (System Settings › Apple Intelligence & Siri)."
    case .unavailable(.modelNotReady): return "Apple's model is still downloading."
    case .unavailable: return "Apple's on-device model isn't available."
    }
}

let model = SystemLanguageModel.default
if CommandLine.arguments.contains("--status") {
    if let reason = unavailableReason(model.availability) { reply(["available": false, "reason": reason]) }
    reply(["available": true])
}
if let reason = unavailableReason(model.availability) { reply(["error": reason, "unavailable": true]) }

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let request = try? JSONDecoder().decode(Request.self, from: input) else { reply(["error": "Expected {\"instructions\", \"prompt\"} on stdin."]) }
do {
    let session = LanguageModelSession(model: model, instructions: request.instructions)
    let response = try await session.respond(to: request.prompt, options: GenerationOptions(temperature: 0.2))
    reply(["text": response.content])
} catch {
    reply(["error": "Apple's on-device model failed: \(error.localizedDescription)"])
}
