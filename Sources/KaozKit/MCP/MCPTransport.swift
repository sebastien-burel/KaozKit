import Foundation

/// One POST to an MCP server: the JSON-RPC body, the method it names (and
/// the tool, for a call), and the headers the client adds.
public struct MCPRequest: Sendable {
    public var body: Data
    public var method: String
    public var name: String?
    public var headers: [String: String]

    public init(body: Data, method: String, name: String? = nil, headers: [String: String] = [:]) {
        self.body = body
        self.method = method
        self.name = name
        self.headers = headers
    }
}

/// What came back, headers by lowercased name.
public struct MCPReply: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.body = body
    }
}

/// How the client reaches a server. Streamable HTTP for a remote one; a
/// test swaps in a scripted server.
public protocol MCPTransport: Sendable {
    func send(_ request: MCPRequest) async throws -> MCPReply
}

/// Streamable HTTP: every message is a POST to the server's one endpoint;
/// the answer is a JSON body or a request-scoped event stream, read to its
/// end.
public struct StreamableHTTPTransport: MCPTransport {
    public let url: URL
    let session: URLSession
    let timeout: TimeInterval
    /// The bearer token to present, if any — asked on every request, so a
    /// refreshed token is picked up.
    let authorization: @Sendable () async -> String?

    public init(url: URL, session: URLSession = .shared, timeout: TimeInterval = 60,
                authorization: @escaping @Sendable () async -> String? = { nil }) {
        self.url = url
        self.session = session
        self.timeout = timeout
        self.authorization = authorization
    }

    public func send(_ request: MCPRequest) async throws -> MCPReply {
        var http = URLRequest(url: url)
        http.httpMethod = "POST"
        http.timeoutInterval = timeout
        http.httpBody = request.body
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        // The 2026-07-28 revision mirrors the method and the tool in headers
        // so that intermediaries can route without reading the body.
        http.setValue(request.method, forHTTPHeaderField: "Mcp-Method")
        if let name = request.name { http.setValue(name, forHTTPHeaderField: "Mcp-Name") }
        for (field, value) in request.headers { http.setValue(value, forHTTPHeaderField: field) }
        if let token = await authorization() { http.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: http)
        guard let response = response as? HTTPURLResponse else { throw MCPError.malformed("pas une réponse HTTP") }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { all, field in
            if let name = field.key as? String, let value = field.value as? String { all[name] = value }
        }
        return MCPReply(status: response.statusCode, headers: headers, body: data)
    }
}
