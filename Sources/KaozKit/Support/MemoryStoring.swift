import Foundation

/// Abstraction over the durable "pinned preferences" memory store. The agent
/// runtime and the memory tools depend on this protocol rather than on the
/// app's concrete `@MainActor MemoryStore`, so a headless consumer (kaoz)
/// can supply a plain file-backed implementation. The app conforms its own
/// `MemoryStore` to it.
@MainActor
public protocol MemoryStoring: AnyObject, Sendable {
    var memories: [Memory] { get }
    @discardableResult
    func add(title: String, content: String) -> Memory
    func update(id: UUID, title: String, content: String)
    func delete(id: UUID)
    func memory(id: UUID) -> Memory?
}

public extension MemoryStoring {
    /// Pins `content` under `title` — or, when an entry already carries that
    /// title (see `Memory.titleKey`), replaces its content: saying a thing
    /// twice must not pin it twice. What every writer goes through.
    @discardableResult
    func remember(title: String, content: String) -> (memory: Memory, replaced: Bool) {
        let title = Memory.tidyTitle(title)
        let key = Memory.titleKey(title)
        if !key.isEmpty, let existing = memories.last(where: { Memory.titleKey($0.title) == key }) {
            update(id: existing.id, title: title, content: content)
            return (memory(id: existing.id) ?? existing, true)
        }
        return (add(title: title, content: content), false)
    }
}
