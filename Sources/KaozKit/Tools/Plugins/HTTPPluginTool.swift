import Foundation

/// Bridges a plugin's tool definition to the `Tool` protocol. When invoked it
/// calls the configured HTTP endpoint — POST sends the arguments as the JSON
/// body, GET maps them to query items — and returns the response body as text.
///
/// A plugin may hold several accounts — the same secrets, another value for
/// each. With two or more, the model names the account in an extra
/// argument, removed before the request.
public struct HTTPPluginTool: Tool {
    /// One set of values for the plugin's secrets, under a label the model
    /// picks it by.
    public struct Account: Sendable, Equatable {
        public let id: String
        public let label: String
        public let secrets: [String: String]

        public init(id: String, label: String, secrets: [String: String]) {
            self.id = id
            self.label = label
            self.secrets = secrets
        }
    }

    let definition: PluginToolDef
    /// Never empty.
    public let accounts: [Account]
    let session: URLSession

    public init(definition: PluginToolDef, secrets: [String: String] = [:], session: URLSession = .shared) {
        self.init(definition: definition, accounts: [Account(id: "", label: "", secrets: secrets)], session: session)
    }

    public init(definition: PluginToolDef, accounts: [Account], session: URLSession = .shared) {
        precondition(!accounts.isEmpty, "a plugin tool needs an account")
        self.definition = definition
        self.accounts = accounts
        self.session = session
    }

    /// The same tool with only the accounts in `ids`; nil if none is left.
    public func restricted(to ids: Set<String>) -> HTTPPluginTool? {
        let kept = accounts.filter { ids.contains($0.id) }
        return kept.isEmpty ? nil : HTTPPluginTool(definition: definition, accounts: kept, session: session)
    }

    /// The argument naming the account, when there is a choice: `account`,
    /// unless the manifest already has one.
    public var accountArgument: String? {
        guard accounts.count > 1 else { return nil }
        return Self.properties(of: definition.inputSchemaJSON)?["account"] == nil ? "account" : "tykaoz_account"
    }

    /// The label of the account a call acts with: the one it names when
    /// there is a choice, else the only one's, if it has a name.
    public func accountLabel(in arguments: Data) -> String? {
        guard let argument = accountArgument else { return accounts[0].label.isEmpty ? nil : accounts[0].label }
        return ((try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any])?[argument] as? String
    }

    private static func properties(of schemaJSON: String) -> [String: Any]? {
        ((try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8))) as? [String: Any])?["properties"] as? [String: Any]
    }

    private static let maxResponseChars = 100_000

    /// The server it calls, for the app to say where the arguments go.
    public var host: String? { definition.host }

    /// Whether it calls with the user's secrets: its answers may then be
    /// the user's own data, from their account.
    public var usesSecrets: Bool { !definition.secretNames.isEmpty }

    public var spec: ToolSpec {
        ToolSpec(
            name: definition.name,
            description: definition.description,
            inputSchemaJSON: schemaJSON
        )
    }

    /// The manifest's schema, with the account to choose when there is a choice.
    private var schemaJSON: String {
        guard let argument = accountArgument,
              var schema = (try? JSONSerialization.jsonObject(with: Data(definition.inputSchemaJSON.utf8))) as? [String: Any]
        else { return definition.inputSchemaJSON }
        var properties = schema["properties"] as? [String: Any] ?? [:]
        properties[argument] = [
            "type": "string",
            "enum": accounts.map(\.label),
            "description": "Which account to act with.",
        ]
        schema["properties"] = properties
        schema["required"] = (schema["required"] as? [String] ?? []) + [argument]
        guard let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return definition.inputSchemaJSON }
        return text
    }

    public func execute(arguments: Data) async throws -> String {
        var arguments = arguments
        var secrets = accounts[0].secrets
        if let argument = accountArgument {
            var object = ((try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any]) ?? [:]
            let label = object.removeValue(forKey: argument) as? String
            guard let account = accounts.first(where: { $0.label == label }) else {
                let labels = accounts.map { "\"\($0.label)\"" }.joined(separator: ", ")
                throw ToolError.execution(message: "\(argument) must be one of: \(labels)")
            }
            secrets = account.secrets
            arguments = try JSONSerialization.data(withJSONObject: object)
        }
        let request = try buildRequest(arguments: arguments, secrets: secrets)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw ToolError.execution(message: "network error: \(urlError.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw ToolError.execution(message: "non-HTTP response")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            let snippet = body.prefix(500)
            throw ToolError.execution(message: "HTTP \(http.statusCode)\(snippet.isEmpty ? "" : " : \(snippet)")")
        }

        return body.count > Self.maxResponseChars
            ? String(body.prefix(Self.maxResponseChars)) + "\n[truncated]"
            : body
    }

    private func buildRequest(arguments: Data, secrets: [String: String]) throws -> URLRequest {
        let argDict = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        let (resolvedURL, usedKeys) = try self.resolvedURL(arguments: argDict, secrets: secrets)

        switch definition.method {
        case .post:
            var request = URLRequest(url: resolvedURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = arguments.isEmpty ? Data("{}".utf8) : arguments
            applyHeaders(&request, secrets: secrets)
            request.timeoutInterval = 30
            return request

        case .get:
            guard var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false) else {
                throw ToolError.execution(message: "invalid URL")
            }
            // Append only the arguments not already consumed by {placeholders}
            // in the URL path/query.
            let items = argDict
                .filter { !usedKeys.contains($0.key) }
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: Self.stringify($0.value)) }
            if !items.isEmpty {
                components.queryItems = (components.queryItems ?? []) + items
            }
            guard let url = components.url else {
                throw ToolError.execution(message: "cannot build the URL")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            applyHeaders(&request, secrets: secrets)
            request.timeoutInterval = 30
            return request
        }
    }

    /// Substitutes secret then argument placeholders in the URL template and
    /// returns the resulting URL plus the argument names consumed by it.
    private func resolvedURL(arguments: [String: Any], secrets: [String: String]) throws -> (URL, Set<String>) {
        let withSecrets = PluginSecrets.substitute(in: definition.urlTemplate, secrets: secrets)
        let (filled, usedKeys) = PluginArguments.substitute(in: withSecrets, arguments: arguments)
        guard let url = URL(string: filled) else {
            throw ToolError.execution(message: "invalid URL after substitution: \(filled)")
        }
        return (url, usedKeys)
    }

    private func applyHeaders(_ request: inout URLRequest, secrets: [String: String]) {
        for (key, value) in definition.headers {
            request.setValue(
                PluginSecrets.substitute(in: value, secrets: secrets),
                forHTTPHeaderField: key
            )
        }
    }

    /// JSONSerialization hands us NSNumber for every numeric/bool; `as? Bool`
    /// then matches *any* NSNumber whose value is 0 or 1 (the bridging trap),
    /// so we must check the underlying CF type to tell `true` from `1`.
    private static func stringify(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        return String(describing: value)
    }
}
