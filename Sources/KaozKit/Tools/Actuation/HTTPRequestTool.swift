import Foundation

/// Makes an outbound HTTP request (any method) and returns { status, body }.
/// This is the universal **outbound channel**: an agent posts to a Slack /
/// Telegram / Discord webhook or any REST API. Opt-in and, optionally, host-
/// restricted (an allowlist mitigates SSRF to internal services). Distinct from
/// the read-only `fetch_url` tool (GET + HTML-strip): this one sends bodies and
/// headers and returns the raw response.
public struct HTTPRequestTool: Tool {
    /// nil = any host allowed; otherwise the request host must match one of these.
    public let allowedHosts: [String]?
    /// Un défaut bas parce que la plupart des réponses sont lues par un modèle
    /// qui paie chaque caractère ; un plafond haut parce que certaines sont des
    /// images qu'un programme veut récupérer entières.
    private static let maxBodyBytes = 200_000
    private static let maxBodyBytesCeiling = 8_000_000

    public init(allowedHosts: [String]? = nil) {
        self.allowedHosts = allowedHosts
    }

    public let spec = ToolSpec(
        name: "http_request",
        description: """
        Sends an HTTP request and returns { status, body }. Use it to call REST
        APIs or post to webhooks (Slack/Telegram/Discord/…). method defaults to
        GET; headers and body are optional. The body is returned as text, capped.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "url": { "type": "string", "description": "Absolute http(s) URL." },
            "method": { "type": "string", "description": "GET, POST, PUT, … (default GET)." },
            "headers": { "type": "object", "description": "Header name → value.", "additionalProperties": { "type": "string" } },
            "body": { "type": "string", "description": "Request body (for POST/PUT/…)." },
            "max_bytes": { "type": "integer", "description": "Response bytes to keep (default 200000). Raise it to fetch a whole image.", "minimum": 1024, "maximum": 8000000 }
          },
          "required": ["url"],
          "additionalProperties": false
        }
        """
    )

    private struct Args: Decodable {
        let url: String
        let method: String?
        let headers: [String: String]?
        let body: String?
        let maxBytes: Int?

        enum CodingKeys: String, CodingKey {
            case url, method, headers, body
            case maxBytes = "max_bytes"
        }
    }

    public func execute(arguments: Data) async throws -> String {
        guard let args = try? JSONDecoder().decode(Args.self, from: arguments) else {
            throw ToolError.invalidArguments(reason: "expected {url, method?, headers?, body?}")
        }
        guard let url = URL(string: args.url), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw ToolError.invalidArguments(reason: "url must be an absolute http(s) URL")
        }
        if let allowedHosts, let host = url.host,
           !allowedHosts.contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame }) {
            throw ToolError.execution(message: "host « \(host) » is not in the allowed list")
        }

        var request = URLRequest(url: url)
        request.httpMethod = (args.method ?? "GET").uppercased()
        for (k, v) in args.headers ?? [:] {
            let clean = v.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            request.setValue(clean, forHTTPHeaderField: k)
        }
        if let body = args.body { request.httpBody = Data(body.utf8) }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let limit = min(args.maxBytes ?? Self.maxBodyBytes, Self.maxBodyBytesCeiling)
            let capped = data.prefix(limit)
            let contentType = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Type") ?? ""
            var result: [String: Any] = ["status": status, "contentType": contentType]
            // Une réponse binaire — une image, typiquement — ne survit pas à un
            // décodage UTF-8 : elle en ressortait chaîne vide. On la rend en
            // base64 plutôt que de la perdre en silence.
            if let text = String(data: capped, encoding: .utf8) {
                result["body"] = text
            } else {
                result["base64"] = capped.base64EncodedString()
            }
            guard let json = (try? JSONSerialization.data(withJSONObject: result))
                .flatMap({ String(data: $0, encoding: .utf8) }) else {
                throw ToolError.execution(message: "http_request: réponse non sérialisable")
            }
            return json
        } catch {
            throw ToolError.execution(message: "http_request failed: \(error.localizedDescription)")
        }
    }
}
