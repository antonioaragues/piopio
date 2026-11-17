extension SessionEvent {
    /// The same events with back-to-back text deltas of one part joined into one delta.
    /// Streaming sends a delta per token; the transcript re-renders the open block once per delta,
    /// so a frame's worth of tokens should arrive as one. Order and every other event stay as they were.
    public static func coalesced(_ events: [SessionEvent]) -> [SessionEvent] {
        guard events.count > 1 else { return events }
        var out: [SessionEvent] = []
        out.reserveCapacity(events.count)
        for event in events {
            if case .itemDelta(let id, let part, let type, let text) = event,
               case .itemDelta(let lastId, let lastPart, let lastType, let lastText)? = out.last,
               id == lastId, part == lastPart, type == lastType {
                out[out.count - 1] = .itemDelta(itemId: id, partIndex: part, partType: type, textDelta: lastText + text)
            } else {
                out.append(event)
            }
        }
        return out
    }
}
