import Foundation

/// Client-side projection of a session: a snapshot plus applied event batches.
/// The engine is the source of truth; this mirrors it for rendering.
public struct Transcript: Sendable {
    public private(set) var ref: ContainerRef
    public private(set) var items: [TimelineItem]
    public private(set) var state: SessionState

    public init(snapshot: Snapshot) {
        ref = snapshot.ref
        items = snapshot.items
        state = snapshot.state
    }

    public mutating func apply(_ events: [SessionEvent]) {
        for event in events { apply(event) }
    }

    public mutating func apply(_ event: SessionEvent) {
        switch event {
        case .itemAdded(let item):
            if let i = index(of: item.id) { items[i] = item } else { items.append(item) }
        case .itemInserted(let item, let before):
            if let i = index(of: item.id) { items[i] = item } else if let b = index(of: before) { items.insert(item, at: b) } else { items.append(item) }
        case .itemUpdated(let item):
            if let i = index(of: item.id) { items[i] = item }
        case .itemReplaced(let oldId, let item):
            if let i = index(of: oldId) { items[i] = item } else { items.append(item) }
        case .itemRemoved(let id):
            items.removeAll { $0.id == id }
        case .itemDelta(let id, let partIndex, let partType, let delta):
            guard let i = index(of: id), case .assistant(var a) = items[i] else { return }
            while a.parts.count <= partIndex { a.parts.append(AssistantPart(type: partType, text: "", redacted: nil)) }
            a.parts[partIndex].text += delta
            items[i] = .assistant(a)
        case .state(let s):
            state = s
        case .resnapshot(let snapshot):
            self = Transcript(snapshot: snapshot)
        case .unknown:
            break
        }
    }

    private func index(of id: String) -> Int? { items.lastIndex { $0.id == id } }
}
