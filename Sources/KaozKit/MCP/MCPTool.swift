import CryptoKit
import Foundation

/// A connector's tool as the model sees it: an ordinary `Tool`, run by the
/// connector's server. No provider needs to know where it comes from.
public struct MCPTool: Tool {
    public let spec: ToolSpec
    /// The name the server knows it by.
    public let remoteName: String
    public let definition: MCPToolDefinition
    let client: MCPClient
    let maxCharacters: Int

    public init(connector: String, definition: MCPToolDefinition, client: MCPClient, maxCharacters: Int = 100_000) {
        self.spec = ToolSpec(
            name: MCPToolNaming.exposedName(connector: connector, tool: definition.name),
            description: definition.description,
            inputSchemaJSON: definition.inputSchemaJSON)
        self.remoteName = definition.name
        self.definition = definition
        self.client = client
        self.maxCharacters = maxCharacters
    }

    /// Whether the tool may run without asking: only one its server says
    /// only reads. Unknown counts as writing.
    public var readsOnly: Bool { definition.readOnly == true && definition.destructive != true }

    public func execute(arguments: Data) async throws -> String {
        let result: MCPCallResult
        do {
            result = try await client.callTool(name: remoteName, arguments: arguments)
        } catch let error as MCPError {
            throw ToolError.execution(message: error.errorDescription ?? "Le connecteur n'a pas répondu.")
        }
        let text = result.text.count > maxCharacters
            ? String(result.text.prefix(maxCharacters)) + "\n[… réponse tronquée]"
            : result.text
        if result.isError { throw ToolError.execution(message: text.isEmpty ? "Le connecteur a signalé une erreur." : text) }
        return text
    }
}

/// The names connectors' tools take before the model: `connector__tool`,
/// within what every provider accepts — `[a-zA-Z0-9_-]`, 64 characters.
public enum MCPToolNaming {
    public static let maxLength = 64

    public static func exposedName(connector: String, tool: String) -> String {
        let name = "\(slug(connector))__\(slug(tool))"
        guard name.count > maxLength else { return name }
        // Too long: cut, and keep it apart from a neighbour cut the same way.
        let digest = SHA256.hash(data: Data(name.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return String(name.prefix(maxLength - digest.count - 1)) + "_" + digest
    }

    /// Lowercase ASCII letters, digits, `_` and `-`; anything else, accents
    /// first stripped, becomes `_`.
    static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let mapped = folded.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "0"..."9", "_", "-": return Character(scalar)
            case "A"..."Z": return Character(Unicode.Scalar(scalar.value + 32)!)
            default: return "_"
            }
        }
        let slug = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return slug.isEmpty ? "outil" : slug
    }
}
