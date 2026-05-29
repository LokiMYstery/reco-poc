import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RecommendationResult: Codable, Equatable, Identifiable, Sendable {
    public var id: String { requestID }
    public let userID: String
    public let virtualUserKey: String
    public let requestID: String
    public let topScenes: [String]
    public let latencyMs: Int
    public let errorMessage: String?

    public init(userID: String, virtualUserKey: String, requestID: String, topScenes: [String], latencyMs: Int, errorMessage: String? = nil) {
        self.userID = userID
        self.virtualUserKey = virtualUserKey
        self.requestID = requestID
        self.topScenes = topScenes
        self.latencyMs = latencyMs
        self.errorMessage = errorMessage
    }

    public var isSuccess: Bool { errorMessage == nil && !topScenes.isEmpty }
    public var top1: String? { topScenes.first }
}

public protocol RecommendationAPIClient: Sendable {
    func recommend(_ request: RecommendRequest, virtualUserKey: String) async -> RecommendationResult
    func sendFeedback(_ request: FeedbackRequest) async -> Result<Void, Error>
}

public protocol RecommendationRequestIDGenerating: Sendable {
    func nextRequestID(virtualUserKey: String, snapshot: RawSensorSnapshot) -> String
}

public struct DefaultRecommendationRequestIDGenerator: RecommendationRequestIDGenerating {
    public init() {}

    public func nextRequestID(virtualUserKey: String, snapshot: RawSensorSnapshot) -> String {
        "req_\(virtualUserKey)_\(UUID().uuidString.lowercased())"
    }
}

public struct TimestampRecommendationRequestIDGenerator: RecommendationRequestIDGenerating {
    public init() {}

    public func nextRequestID(virtualUserKey: String, snapshot: RawSensorSnapshot) -> String {
        "req_\(virtualUserKey)_\(Int(snapshot.capturedAt.timeIntervalSince1970))"
    }
}

public struct APIClientError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public enum LiveRecommendationAPIClientError: Error, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int, String)
}

public actor LiveRecommendationAPIClient: RecommendationAPIClient {
    private struct RecommendationResponse: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let scene: String
        }

        let requestID: String
        let userID: String
        let recommendations: [Item]

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case userID = "user_id"
            case recommendations
        }
    }

    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func recommend(_ request: RecommendRequest, virtualUserKey: String) async -> RecommendationResult {
        let startedAt = Date()
        do {
            let response = try await post(path: "/v1/recommend", payload: request, responseType: RecommendationResponse.self)
            return RecommendationResult(
                userID: response.userID,
                virtualUserKey: virtualUserKey,
                requestID: response.requestID,
                topScenes: response.recommendations.map(\.scene),
                latencyMs: Self.latencyMs(since: startedAt)
            )
        } catch {
            return RecommendationResult(
                userID: request.userID,
                virtualUserKey: virtualUserKey,
                requestID: request.requestID,
                topScenes: [],
                latencyMs: Self.latencyMs(since: startedAt),
                errorMessage: String(describing: error)
            )
        }
    }

    public func sendFeedback(_ request: FeedbackRequest) async -> Result<Void, Error> {
        struct FeedbackResponse: Decodable { let ok: Bool }
        do {
            let response = try await post(path: "/v1/feedback", payload: request, responseType: FeedbackResponse.self)
            return response.ok ? .success(()) : .failure(APIClientError("feedback response ok=false"))
        } catch {
            return .failure(error)
        }
    }

    private func post<Payload: Encodable, Response: Decodable>(path: String, payload: Payload, responseType: Response.Type) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiveRecommendationAPIClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw LiveRecommendationAPIClientError.httpStatus(httpResponse.statusCode, message)
        }
        return try decoder.decode(responseType, from: data)
    }

    private static func latencyMs(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }
}

public final class FakeRecommendationAPIClient: RecommendationAPIClient, @unchecked Sendable {
    public var failFeedback: Bool
    public var failedRecommendKeys: Set<String>

    private let lock = NSLock()
    private var recommendRequestStorage: [RecommendRequest] = []
    private var feedbackRequestStorage: [FeedbackRequest] = []
    private var feedbackAttemptsStorage: [String: Int] = [:]
    private var transientFeedbackFailuresByRequestID: [String: Int]

    public init(
        failFeedback: Bool = false,
        failedRecommendKeys: Set<String> = [],
        transientFeedbackFailuresByRequestID: [String: Int] = [:]
    ) {
        self.failFeedback = failFeedback
        self.failedRecommendKeys = failedRecommendKeys
        self.transientFeedbackFailuresByRequestID = transientFeedbackFailuresByRequestID
    }

    public var recommendRequests: [RecommendRequest] {
        lock.withLock { recommendRequestStorage }
    }

    public var feedbackRequests: [FeedbackRequest] {
        lock.withLock { feedbackRequestStorage }
    }

    public var feedbackAttempts: [String: Int] {
        lock.withLock { feedbackAttemptsStorage }
    }

    public func recommend(_ request: RecommendRequest, virtualUserKey: String) async -> RecommendationResult {
        lock.withLock { recommendRequestStorage.append(request) }
        if failedRecommendKeys.contains(virtualUserKey) {
            return RecommendationResult(
                userID: request.userID,
                virtualUserKey: virtualUserKey,
                requestID: request.requestID,
                topScenes: [],
                latencyMs: 12,
                errorMessage: "simulated failure"
            )
        }
        let topScenes = recommendationScenes(for: request.context)
        return RecommendationResult(
            userID: request.userID,
            virtualUserKey: virtualUserKey,
            requestID: request.requestID,
            topScenes: topScenes,
            latencyMs: 24
        )
    }

    public func sendFeedback(_ request: FeedbackRequest) async -> Result<Void, Error> {
        lock.withLock {
            feedbackRequestStorage.append(request)
            feedbackAttemptsStorage[request.requestID, default: 0] += 1
        }

        if failFeedback {
            return .failure(APIClientError("simulated feedback failure"))
        }

        let shouldFailTransiently = lock.withLock { () -> Bool in
            let remaining = transientFeedbackFailuresByRequestID[request.requestID, default: 0]
            if remaining > 0 {
                transientFeedbackFailuresByRequestID[request.requestID] = remaining - 1
                return true
            }
            return false
        }

        if shouldFailTransiently {
            return .failure(APIClientError("simulated transient feedback failure"))
        }

        return .success(())
    }

    private func recommendationScenes(for context: [String: JSONValue]) -> [String] {
        if context["initial_need"]?.stringValue == InitialNeed.sleep.rawValue { return ["深睡眠", "睡午觉", "冥想"] }
        if context["activity_state"]?.stringValue == "中速" { return ["跑步", "健身", "瑜伽"] }
        if context["place_type"]?.stringValue == "写字楼" { return ["专注", "放松", "阅读"] }
        return ["放松", "专注", "冥想"]
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
