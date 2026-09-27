import Foundation

/// Lets the model persist a fact worth remembering across conversations.
public struct SaveMemoryTool: Tool {
    public let store: MemoryStoring

    public init(store: MemoryStoring) {
        self.store = store
    }

    public let spec = ToolSpec(
        name: "save_memory",
        description: """
        Pins a small, stable fact about the user themself so it's always in
        context: their first name, preferred language, tone, how they like
        answers. NOT for the people around them (family, colleagues), a
        project or a topic — that goes in the wiki via write_wiki_page. Not
        for one-off chatter. Never pin a value that changes with time — an
        age, a time elapsed, "three weeks old": pin what it derives from (a
        birth date, a start date). Saving under a title already pinned
        replaces its content. Provide a short title and the content.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "title": {
              "type": "string",
              "description": "Short label for the memory (a few words)."
            },
            "content": {
              "type": "string",
              "description": "The information to remember."
            }
          },
          "required": ["content"],
          "additionalProperties": false
        }
        """
    )

    private struct Args: Decodable {
        let title: String?
        let content: String
    }

    public func execute(arguments: Data) async throws -> String {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            let raw = String(data: arguments, encoding: .utf8) ?? "<binary>"
            throw ToolError.invalidArguments(
                reason: "expected {title?: string, content: string}, got: \(raw)"
            )
        }
        let content = args.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw ToolError.invalidArguments(reason: "content must not be empty")
        }

        let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = (title?.isEmpty == false) ? title! : Self.deriveTitle(from: content)

        // A pinned "21 days" is wrong by next week. Refusing, with today's
        // date, lets the model pin the date instead — or nothing.
        guard !Memory.mentionsRelativeDuration(resolvedTitle),
              !Memory.mentionsRelativeDuration(content)
        else {
            let today = Date.now.formatted(.iso8601.year().month().day())
            throw ToolError.invalidArguments(reason: """
                not saved: "\(content)" states a span of time, which is wrong \
                soon after. Pin the date it derives from instead — today is \
                \(today), so "3 weeks old" becomes "born around" the date 21 days \
                before. Or don't pin it.
                """)
        }

        let (memory, replaced) = await store.remember(title: resolvedTitle, content: content)
        return "\(replaced ? "Updated" : "Saved") \"\(memory.title)\" (id \(memory.id.uuidString))."
    }

    /// Falls back to the first words of the content when no title is given.
    private static func deriveTitle(from content: String) -> String {
        let firstLine = content.split(separator: "\n").first.map(String.init) ?? content
        return String(firstLine.prefix(40))
    }
}
