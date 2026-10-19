import Foundation

/// What can go wrong talking to an MCP server, as the app needs to tell it.
public enum MCPError: Error, Equatable, LocalizedError {
    /// The server wants a token: its `WWW-Authenticate` says where to get one.
    case unauthorized(wwwAuthenticate: String?)
    /// An HTTP failure that is not the protocol's own.
    case http(status: Int, body: String)
    /// A JSON-RPC error the server answered.
    case rpc(code: Int, message: String)
    /// A reply that is not what the protocol says.
    case malformed(String)
    /// The server needs more from the user before it answers (an
    /// authorization step, a choice): not handled yet.
    case inputRequired

    public var errorDescription: String? {
        switch self {
        case .unauthorized:            return "Le connecteur demande une connexion."
        case .http(let status, _):     return "Le connecteur a répondu \(status)."
        case .rpc(_, let message):     return message
        case .malformed(let reason):   return "Réponse du connecteur illisible : \(reason)"
        case .inputRequired:           return "Le connecteur demande une action de votre part."
        }
    }
}

/// JSON-RPC as MCP writes it, over either era of the protocol.
enum MCPWire {
    /// A request, with an id; `params` nil leaves the field out.
    static func request(id: Int, method: String, params: [String: Any]?) -> Data {
        var body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { body["params"] = params }
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// A notification: no id, no answer expected.
    static func notification(method: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method])) ?? Data()
    }

    /// The JSON-RPC message answering `id`, whether the server sent a plain
    /// JSON body or a request-scoped SSE stream (lines ending in `\n` or
    /// `\r\n`, one or more `data:` lines per event).
    static func reply(to id: Int, body: Data, contentType: String?) throws -> [String: Any] {
        let messages: [[String: Any]]
        if contentType?.lowercased().contains("text/event-stream") == true {
            messages = events(in: body).compactMap { object($0) }
        } else if let one = object(body) {
            messages = [one]
        } else {
            throw MCPError.malformed("ni JSON ni flux d'événements")
        }
        // A server may push notifications on the stream before the answer.
        if let answer = messages.first(where: { ($0["id"] as? Int) == id }) { return answer }
        // An error sent before the request could be read has no id.
        if let anonymous = messages.first(where: { $0["id"] == nil && $0["error"] != nil }) { return anonymous }
        throw MCPError.malformed("aucune réponse à la requête \(id)")
    }

    /// The `result` of a reply, or its error.
    static func result(of reply: [String: Any]) throws -> [String: Any] {
        if let error = reply["error"] as? [String: Any] {
            throw MCPError.rpc(code: error["code"] as? Int ?? 0, message: error["message"] as? String ?? "erreur")
        }
        guard let result = reply["result"] as? [String: Any] else { throw MCPError.malformed("ni résultat ni erreur") }
        return result
    }

    /// The data of each event of an SSE body, the `data:` lines of an event
    /// joined by newlines.
    static func events(in body: Data) -> [Data] {
        let text = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var events: [Data] = []
        var lines: [String] = []
        func flush() {
            if !lines.isEmpty { events.append(Data(lines.joined(separator: "\n").utf8)) }
            lines = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { flush(); continue }
            guard line.hasPrefix("data:") else { continue }
            var value = line.dropFirst(5)
            if value.first == " " { value = value.dropFirst() }
            lines.append(String(value))
        }
        flush()
        return events
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
