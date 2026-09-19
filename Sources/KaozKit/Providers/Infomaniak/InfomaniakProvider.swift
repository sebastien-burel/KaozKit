import Foundation

/// Infomaniak AI Tools, over its OpenAI-compatible endpoint.
///
/// The endpoint is scoped to an AI Tools *product*: `/2/ai/{product_id}/openai/v1`.
/// The product id is not on the key — it comes from `GET /1/ai`, which lists the
/// account's products; `productID(apiKey:)` picks the one that is `ok`. Models
/// come from Infomaniak's own `GET /1/ai/models`, not the OpenAI list.
public struct InfomaniakProvider: LLMProvider {
    public let id: String = "infomaniak"
    public let displayName: String = "Infomaniak"

    public let apiKey: String
    public let productID: Int
    public let model: String

    private let client: OpenAICompatibleClient

    public static let apiRoot = URL(string: "https://api.infomaniak.com")!

    /// The OpenAI-compatible root of one product.
    public static func baseURL(productID: Int) -> URL {
        apiRoot.appending(path: "/2/ai/\(productID)/openai/v1")
    }

    public init(apiKey: String, productID: Int, model: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.productID = productID
        self.model = model
        self.client = OpenAICompatibleClient(
            baseURL: Self.baseURL(productID: productID), apiKey: apiKey, session: session)
    }

    public func availability() async -> ProviderAvailability {
        guard !apiKey.isEmpty else {
            return .unavailable(reason: "Enter your Infomaniak API key in Settings.")
        }
        do {
            let models = try await Self.listModels(apiKey: apiKey, session: client.session)
            guard models.contains(model) else {
                return .unavailable(reason: "Model \"\(model)\" is not accessible with this key.")
            }
            return .ready
        } catch let error as OpenAICompatibleError {
            return .unavailable(reason: error.errorDescription ?? "Erreur.")
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    public func chat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<StreamEvent, Error> {
        client.chat(model: model, messages: messages, tools: tools)
    }

    // MARK: - Infomaniak's own endpoints

    /// The id of the account's AI Tools product, the first one whose status is `ok`.
    public static func productID(apiKey: String, session: URLSession = .shared) async throws -> Int {
        let data = try await get("/1/ai", apiKey: apiKey, session: session)
        return try parseProductID(data)
    }

    /// The ids of the language models the key can use, sorted.
    public static func listModels(apiKey: String, session: URLSession = .shared) async throws -> [String] {
        let data = try await get("/1/ai/models", apiKey: apiKey, session: session)
        return try parseModelIDs(data)
    }

    /// `{"result": "success", "data": [...]}` — Infomaniak's envelope, or its
    /// `{"result": "error", "error": {"description": ...}}`.
    private struct Envelope<T: Decodable>: Decodable {
        let result: String
        let data: T?
        let error: APIError?
        struct APIError: Decodable { let description: String? }
    }

    private struct Product: Decodable {
        let productID: Int?
        let status: String?
        enum CodingKeys: String, CodingKey { case productID = "product_id", status }
    }

    private struct Model: Decodable {
        let name: String
        let type: String?
    }

    static func parseProductID(_ data: Data) throws -> Int {
        let products = try decode(Envelope<[Product]>.self, from: data)
        guard let product = products.first(where: { $0.status == "ok" }), let id = product.productID else {
            throw OpenAICompatibleError.decoding(message: "No active AI Tools product on this account.")
        }
        return id
    }

    static func parseModelIDs(_ data: Data) throws -> [String] {
        let models = try decode(Envelope<[Model]>.self, from: data)
        return models.filter { $0.type == "llm" }.map(\.name).sorted()
    }

    private static func decode<T: Decodable>(_: Envelope<T>.Type, from data: Data) throws -> T {
        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw OpenAICompatibleError.decoding(message: error.localizedDescription)
        }
        guard envelope.result == "success", let payload = envelope.data else {
            throw OpenAICompatibleError.decoding(
                message: envelope.error?.description ?? "Infomaniak answered \"\(envelope.result)\".")
        }
        return payload
    }

    private static func get(_ path: String, apiKey: String, session: URLSession) async throws -> Data {
        var request = URLRequest(url: apiRoot.appending(path: path))
        request.timeoutInterval = 10
        request.setValue(
            "Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw OpenAICompatibleError.network(message: urlError.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleError.network(message: "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenAICompatibleError.http(status: http.statusCode, body: body)
        }
        return data
    }
}
