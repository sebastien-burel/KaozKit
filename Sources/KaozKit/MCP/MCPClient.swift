import Foundation

/// A tool a connector offers, as its server describes it.
public struct MCPToolDefinition: Sendable, Equatable {
    public let name: String
    public let title: String?
    public let description: String
    /// The input schema, as JSON text, for the providers to splice in.
    public let inputSchemaJSON: String
    /// What the server says of the tool. Absent means unknown: a tool that
    /// does not say it only reads is treated as one that writes.
    public let readOnly: Bool?
    public let destructive: Bool?

    public init(name: String, title: String? = nil, description: String, inputSchemaJSON: String,
                readOnly: Bool? = nil, destructive: Bool? = nil) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
        self.readOnly = readOnly
        self.destructive = destructive
    }
}

/// A tool's answer, brought down to text for the model.
public struct MCPCallResult: Sendable, Equatable {
    public let text: String
    public let isError: Bool
}

/// A client for one MCP server, over either era of the protocol:
///
/// - **2026-07-28**, stateless: no handshake, every request carries its
///   version and capabilities in `_meta`; `server/discover` says so.
/// - **2025-03-26 to 2025-11-25**: an `initialize` handshake, and a session
///   when the server gives one (`Mcp-Session-Id`).
///
/// The client tries the first and falls back to the second, as the
/// specification describes. Tools only, for now: resources, prompts and
/// server-initiated input wait for later phases.
public actor MCPClient {
    public enum Era: Sendable, Equatable {
        case stateless
        case session(version: String, id: String?)
    }

    public static let currentVersion = "2026-07-28"
    /// What the handshake proposes to an older server: the last revision
    /// with sessions. A server answers with the one it speaks.
    public static let handshakeVersion = "2025-11-25"

    let transport: MCPTransport
    let clientInfo: [String: String]
    public private(set) var era: Era?
    public private(set) var serverName: String?
    private var nextID = 1

    public init(transport: MCPTransport, clientName: String = "TyKaoz", clientVersion: String = "1") {
        self.transport = transport
        self.clientInfo = ["name": clientName, "version": clientVersion]
    }

    // MARK: - Connection

    /// Finds which era the server speaks; done once, before the first call.
    @discardableResult
    public func connect() async throws -> Era {
        if let era { return era }
        let discovered = try await discover()
        let era = try await (discovered ? .stateless : handshake())
        self.era = era
        return era
    }

    /// Whether the server speaks the stateless revision. Any refusal short
    /// of an authorization one means an older server: -32601 (unknown
    /// method), -32602 (no `initialize` before), -32020 (headers), or an
    /// HTTP 400, 404 or 405.
    private func discover() async throws -> Bool {
        let id = takeID()
        let reply = try await transport.send(MCPRequest(
            body: MCPWire.request(id: id, method: "server/discover", params: ["_meta": meta()]),
            method: "server/discover", headers: ["MCP-Protocol-Version": Self.currentVersion]))
        if reply.status == 401 { throw MCPError.unauthorized(wwwAuthenticate: reply.headers["www-authenticate"]) }
        guard (200..<300).contains(reply.status),
              let answer = try? MCPWire.reply(to: id, body: reply.body, contentType: reply.headers["content-type"]),
              let result = try? MCPWire.result(of: answer)
        else { return false }
        if let name = (result["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"] as? [String: Any] {
            serverName = name["name"] as? String
        }
        return (result["supportedVersions"] as? [String])?.contains(Self.currentVersion) == true
    }

    private func handshake() async throws -> Era {
        let id = takeID()
        let params: [String: Any] = [
            "protocolVersion": Self.handshakeVersion, "capabilities": [String: Any](), "clientInfo": clientInfo,
        ]
        let reply = try await transport.send(MCPRequest(
            body: MCPWire.request(id: id, method: "initialize", params: params), method: "initialize"))
        let result = try Self.result(of: reply, id: id)
        guard let version = result["protocolVersion"] as? String else { throw MCPError.malformed("version absente") }
        serverName = (result["serverInfo"] as? [String: Any])?["name"] as? String
        let era = Era.session(version: version, id: reply.headers["mcp-session-id"])
        _ = try? await transport.send(MCPRequest(
            body: MCPWire.notification(method: "notifications/initialized"),
            method: "notifications/initialized", headers: headers(for: era)))
        return era
    }

    // MARK: - Tools

    /// Bounds on what a server may put before the model on every turn.
    public static let maxTools = 200
    public static let maxDescription = 8_000

    /// Every tool the server offers, following the pages it cuts the list in,
    /// within `maxTools`, descriptions cut at `maxDescription`.
    public func listTools() async throws -> [MCPToolDefinition] {
        var tools: [MCPToolDefinition] = []
        var cursor: String?
        for _ in 0..<50 {
            let result = try await call("tools/list", params: cursor.map { ["cursor": $0] } ?? [:])
            for case let tool as [String: Any] in result["tools"] as? [Any] ?? [] {
                guard let name = tool["name"] as? String else { continue }
                let annotations = tool["annotations"] as? [String: Any]
                guard tools.count < Self.maxTools else { break }
                let description = tool["description"] as? String ?? ""
                tools.append(MCPToolDefinition(
                    name: name, title: tool["title"] as? String ?? annotations?["title"] as? String,
                    description: description.count > Self.maxDescription
                        ? String(description.prefix(Self.maxDescription)) + "…" : description,
                    inputSchemaJSON: MCPWire.json(tool["inputSchema"] ?? ["type": "object"]),
                    readOnly: annotations?["readOnlyHint"] as? Bool,
                    destructive: annotations?["destructiveHint"] as? Bool))
            }
            cursor = result["nextCursor"] as? String
            if cursor?.isEmpty ?? true || tools.count >= Self.maxTools { break }
        }
        return tools
    }

    /// Calls a tool with the model's arguments (a JSON object).
    public func callTool(name: String, arguments: Data) async throws -> MCPCallResult {
        let object = arguments.isEmpty ? [String: Any]() : (MCPWire.object(arguments) ?? [:])
        let result = try await call("tools/call", params: ["name": name, "arguments": object], name: name)
        if result["resultType"] as? String == "input_required" { throw MCPError.inputRequired }
        return MCPCallResult(text: Self.text(of: result), isError: result["isError"] as? Bool ?? false)
    }

    /// A tool's content as text: its text parts; a placeholder for what the
    /// model cannot read here; the structured content when nothing else.
    static func text(of result: [String: Any]) -> String {
        var parts: [String] = []
        for case let item as [String: Any] in result["content"] as? [Any] ?? [] {
            switch item["type"] as? String {
            case "text":
                parts.append(item["text"] as? String ?? "")
            case "image", "audio":
                parts.append("[\(item["type"] as? String ?? "") \(item["mimeType"] as? String ?? "")]")
            case "resource":
                let resource = item["resource"] as? [String: Any]
                parts.append(resource?["text"] as? String ?? "[\(resource?["uri"] as? String ?? "ressource")]")
            case "resource_link":
                parts.append("[\(item["name"] as? String ?? "lien") : \(item["uri"] as? String ?? "")]")
            default:
                continue
            }
        }
        let text = parts.joined(separator: "\n")
        if text.isEmpty, let structured = result["structuredContent"] { return MCPWire.json(structured) }
        return text
    }

    // MARK: - Requests

    /// One request in the era found; a session the server forgot (404) is
    /// opened again once.
    private func call(_ method: String, params: [String: Any], name: String? = nil) async throws -> [String: Any] {
        let era = try await connect()
        do {
            return try await send(method, params: params, name: name, era: era)
        } catch MCPError.http(status: 404, let body) where era != .stateless {
            // The server speaks the same era: a new handshake, not a new discovery.
            let renewed = try await handshake()
            self.era = renewed
            // A call is not sent twice: the server may have run it before it
            // lost the session, and a write must not happen twice for one
            // approval. The next call goes on the new session.
            if method == "tools/call" { throw MCPError.http(status: 404, body: body) }
            return try await send(method, params: params, name: name, era: renewed)
        }
    }

    private func send(_ method: String, params: [String: Any], name: String?, era: Era) async throws -> [String: Any] {
        var params = params
        if era == .stateless { params["_meta"] = meta() }
        let id = takeID()
        let reply = try await transport.send(MCPRequest(
            body: MCPWire.request(id: id, method: method, params: params), method: method, name: name,
            headers: headers(for: era)))
        return try Self.result(of: reply, id: id)
    }

    private static func result(of reply: MCPReply, id: Int) throws -> [String: Any] {
        if reply.status == 401 { throw MCPError.unauthorized(wwwAuthenticate: reply.headers["www-authenticate"]) }
        // A JSON-RPC error may come with a 4xx: read it before the status.
        if let answer = try? MCPWire.reply(to: id, body: reply.body, contentType: reply.headers["content-type"]),
           answer["error"] != nil || (200..<300).contains(reply.status) {
            return try MCPWire.result(of: answer)
        }
        guard (200..<300).contains(reply.status) else {
            throw MCPError.http(status: reply.status, body: String(decoding: reply.body.prefix(500), as: UTF8.self))
        }
        throw MCPError.malformed("réponse vide")
    }

    private func headers(for era: Era) -> [String: String] {
        switch era {
        case .stateless:
            return ["MCP-Protocol-Version": Self.currentVersion]
        case .session(let version, let id):
            var headers = ["MCP-Protocol-Version": version]
            if let id { headers["Mcp-Session-Id"] = id }
            return headers
        }
    }

    private func meta() -> [String: Any] {
        [
            "io.modelcontextprotocol/protocolVersion": Self.currentVersion,
            "io.modelcontextprotocol/clientCapabilities": [String: Any](),
            "io.modelcontextprotocol/clientInfo": clientInfo,
        ]
    }

    private func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }
}
