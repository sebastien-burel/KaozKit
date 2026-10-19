import CryptoKit
import Foundation

/// OAuth for MCP connectors (2026-07-28 authorization): the resource names
/// its authorization server, the client identifies itself by a metadata
/// document it hosts (or registers, as a fallback), the user signs in in a
/// browser with PKCE, and the token is bound to the connector's address.
/// The browser itself is the app's business; everything else is here.
public enum MCPAuth {
    /// What a 401 says: where the resource's metadata is, and which scope.
    public struct Challenge: Equatable, Sendable {
        public let resourceMetadata: URL?
        public let scope: String?

        public init(resourceMetadata: URL?, scope: String?) {
            self.resourceMetadata = resourceMetadata
            self.scope = scope
        }
    }

    /// The authorization server a connector sends the user to.
    public struct Server: Equatable, Sendable, Codable {
        public let issuer: String
        public let authorizationEndpoint: URL
        public let tokenEndpoint: URL
        public let registrationEndpoint: URL?
        public let supportsClientMetadataDocument: Bool
        /// Whether the server says who it is in the redirect (`iss`): then the
        /// client must check it.
        public let returnsIssuer: Bool
        /// The connector's canonical address, sent as `resource` (RFC 8707).
        public let resource: String
        public let scope: String?
    }

    /// A token and what renews it.
    public struct Tokens: Equatable, Sendable, Codable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresAt: Date?

        public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
        }

        /// Expired, or about to: renewed a minute ahead.
        public func isExpired(now: Date = .now) -> Bool {
            expiresAt.map { $0.timeIntervalSince(now) < 60 } ?? false
        }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case noMetadata
        case issuerMismatch
        case stateMismatch
        case denied(String)
        case noRegistration
        case tokenRefused(String)

        public var errorDescription: String? {
            switch self {
            case .noMetadata:          return "Le connecteur ne dit pas où se connecter."
            case .issuerMismatch:      return "Le serveur de connexion ne correspond pas à celui annoncé."
            case .stateMismatch:       return "La réponse de connexion ne correspond pas à la demande."
            case .denied(let reason):  return "Connexion refusée : \(reason)"
            case .noRegistration:      return "Ce service n'accepte pas encore TyKaoz comme application."
            case .tokenRefused(let r): return "Le service a refusé le jeton : \(r)"
            }
        }
    }

    /// How the client reaches the network: a test swaps in a script.
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public static func urlSessionFetch(_ session: URLSession = StreamableHTTPTransport.defaultSession) -> Fetch {
        { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw MCPError.malformed("pas une réponse HTTP") }
            return (data, http)
        }
    }

    // MARK: - Discovery

    /// `Bearer resource_metadata="…", scope="…"`.
    public static func challenge(_ header: String?) -> Challenge {
        func value(_ key: String) -> String? {
            guard let header, let range = header.range(of: "\(key)=\"") else { return nil }
            let rest = header[range.upperBound...]
            return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
        }
        return Challenge(resourceMetadata: value("resource_metadata").flatMap(URL.init(string:)), scope: value("scope"))
    }

    /// From the connector's address and its 401 to the authorization server:
    /// the protected-resource metadata (RFC 9728) names it, its own metadata
    /// (RFC 8414, or OpenID's) says where to send the user.
    public static func discover(resource: URL, challenge: Challenge, fetch: Fetch) async throws -> Server {
        var candidates: [URL] = challenge.resourceMetadata.map { [$0] } ?? []
        candidates += wellKnown("oauth-protected-resource", for: resource)
        var metadata: [String: Any]?
        for url in candidates where url.scheme == "https" {
            if let object = try? await json(url, fetch: fetch), object["authorization_servers"] != nil {
                metadata = object
                break
            }
        }
        guard let metadata, let issuerText = (metadata["authorization_servers"] as? [String])?.first,
              let issuer = URL(string: issuerText), issuer.scheme == "https" else { throw Failure.noMetadata }
        var server: [String: Any]?
        for url in wellKnown("oauth-authorization-server", for: issuer) + wellKnown("openid-configuration", for: issuer) {
            if let object = try? await json(url, fetch: fetch), object["authorization_endpoint"] != nil {
                server = object
                break
            }
        }
        guard let server,
              let authorization = (server["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let token = (server["token_endpoint"] as? String).flatMap(URL.init(string:)),
              authorization.scheme == "https", token.scheme == "https"
        else { throw Failure.noMetadata }
        // The server's metadata must be its own (RFC 8414 §3.3).
        guard (server["issuer"] as? String).map({ trimmed($0) == trimmed(issuerText) }) ?? false else {
            throw Failure.issuerMismatch
        }
        let scopes = (metadata["scopes_supported"] as? [String])?.joined(separator: " ")
        return Server(
            issuer: server["issuer"] as? String ?? issuerText,
            authorizationEndpoint: authorization, tokenEndpoint: token,
            registrationEndpoint: (server["registration_endpoint"] as? String).flatMap(URL.init(string:)),
            supportsClientMetadataDocument: server["client_id_metadata_document_supported"] as? Bool ?? false,
            returnsIssuer: server["authorization_response_iss_parameter_supported"] as? Bool ?? false,
            resource: metadata["resource"] as? String ?? resource.absoluteString,
            scope: challenge.scope ?? scopes)
    }

    /// The well-known addresses for `name` under `base`: the path inserted
    /// after the well-known segment, then at the root.
    static func wellKnown(_ name: String, for base: URL) -> [URL] {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return [] }
        let path = base.path == "/" ? "" : base.path
        components.query = nil
        components.fragment = nil
        var urls: [URL] = []
        if !path.isEmpty {
            components.path = "/.well-known/\(name)\(path)"
            if let url = components.url { urls.append(url) }
        }
        components.path = "/.well-known/\(name)"
        if let url = components.url { urls.append(url) }
        return urls
    }

    // MARK: - Signing in

    /// PKCE (RFC 7636), S256.
    public static func pkce() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64URL(Data(bytes))
        return (verifier, base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))))
    }

    public static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    /// Where the browser goes to sign the user in.
    public static func authorizationURL(server: Server, clientID: String, redirectURI: String, state: String,
                                        codeChallenge: String) -> URL? {
        guard var components = URLComponents(url: server.authorizationEndpoint, resolvingAgainstBaseURL: false)
        else { return nil }
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: server.resource),
        ]
        if let scope = server.scope, !scope.isEmpty { items.append(URLQueryItem(name: "scope", value: scope)) }
        components.queryItems = items
        return components.url
    }

    /// The code the browser came back with, once the redirect is checked:
    /// the state sent, and the issuer when the server says it gives one.
    public static func code(from callback: URL, state: String, server: Server) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw Failure.denied(value("error_description") ?? error) }
        guard value("state") == state else { throw Failure.stateMismatch }
        // RFC 9207: a present `iss` must be the issuer asked; required when
        // the server says it sends one.
        if let iss = value("iss") {
            guard trimmed(iss) == trimmed(server.issuer) else { throw Failure.issuerMismatch }
        } else if server.returnsIssuer {
            throw Failure.issuerMismatch
        }
        guard let code = value("code"), !code.isEmpty else { throw Failure.denied("pas de code") }
        return code
    }

    /// Code for tokens.
    public static func exchange(code: String, verifier: String, server: Server, clientID: String,
                                redirectURI: String, fetch: Fetch, now: Date = .now) async throws -> Tokens {
        try await token([
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
            "client_id": clientID, "code_verifier": verifier, "resource": server.resource,
        ], server: server, fetch: fetch, now: now, keeping: nil)
    }

    /// A new access token from the refresh token.
    public static func refresh(_ tokens: Tokens, server: Server, clientID: String, fetch: Fetch,
                               now: Date = .now) async throws -> Tokens {
        guard let refresh = tokens.refreshToken else { throw Failure.tokenRefused("pas de jeton de renouvellement") }
        return try await token([
            "grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID,
            "resource": server.resource,
        ], server: server, fetch: fetch, now: now, keeping: refresh)
    }

    private static func token(_ form: [String: String], server: Server, fetch: Fetch, now: Date,
                              keeping refresh: String?) async throws -> Tokens {
        var request = URLRequest(url: server.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formEncoded(form).utf8)
        let (data, response) = try await fetch(request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(response.statusCode), let access = object["access_token"] as? String else {
            throw Failure.tokenRefused(object["error_description"] as? String ?? object["error"] as? String
                                       ?? "HTTP \(response.statusCode)")
        }
        let lifetime = (object["expires_in"] as? Double) ?? (object["expires_in"] as? Int).map(Double.init)
        return Tokens(accessToken: access, refreshToken: object["refresh_token"] as? String ?? refresh,
                      expiresAt: lifetime.map { now.addingTimeInterval($0) })
    }

    /// Dynamic client registration (RFC 7591), for a server that does not read
    /// client metadata documents. Deprecated by the specification, kept as
    /// its fallback.
    public static func register(server: Server, clientName: String, redirectURIs: [String],
                                fetch: Fetch) async throws -> String {
        guard let endpoint = server.registrationEndpoint, endpoint.scheme == "https" else { throw Failure.noRegistration }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": clientName, "redirect_uris": redirectURIs, "application_type": "native",
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        let (data, response) = try await fetch(request)
        guard (200..<300).contains(response.statusCode),
              let id = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["client_id"] as? String
        else { throw Failure.noRegistration }
        return id
    }

    // MARK: - Helpers

    private static func json(_ url: URL, fetch: Fetch) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await fetch(request)
        guard (200..<300).contains(response.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.noMetadata }
        return object
    }

    static func formEncoded(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func trimmed(_ issuer: String) -> String {
        issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer
    }
}
