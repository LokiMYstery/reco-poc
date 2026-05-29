import Foundation

public struct DependencyContainer: Sendable {
    public var sensorAcquirer: any RawSensorAcquiring
    public var contextDeriver: VirtualContextDeriving
    public var payloadMapper: BackendPayloadMapping
    public var apiClient: any RecommendationAPIClient
    public var feedbackQueue: FeedbackRetryQueue
    public var requestIDGenerator: any RecommendationRequestIDGenerating
    public var virtualUserProvider: any VirtualUserProviding
    public var installIdentityStore: any InstallIdentityStoring
    public var topK: Int

    public init(
        sensorAcquirer: any RawSensorAcquiring,
        contextDeriver: VirtualContextDeriving,
        payloadMapper: BackendPayloadMapping,
        apiClient: any RecommendationAPIClient,
        feedbackQueue: FeedbackRetryQueue,
        requestIDGenerator: any RecommendationRequestIDGenerating = DefaultRecommendationRequestIDGenerator(),
        virtualUserProvider: any VirtualUserProviding = RegistryVirtualUserProvider(),
        installIdentityStore: any InstallIdentityStoring = UserDefaultsInstallIdentityStore(),
        topK: Int = 3
    ) {
        self.sensorAcquirer = sensorAcquirer
        self.contextDeriver = contextDeriver
        self.payloadMapper = payloadMapper
        self.apiClient = apiClient
        self.feedbackQueue = feedbackQueue
        self.requestIDGenerator = requestIDGenerator
        self.virtualUserProvider = virtualUserProvider
        self.installIdentityStore = installIdentityStore
        self.topK = topK
    }

    public static func demo() -> DependencyContainer {
        DependencyContainer(
            sensorAcquirer: FakeRawSensorAcquirer(result: .success(.sampleFullPermission)),
            contextDeriver: VirtualContextDeriver(),
            payloadMapper: BackendPayloadMapper(),
            apiClient: FakeRecommendationAPIClient(),
            feedbackQueue: FeedbackRetryQueue(),
            requestIDGenerator: TimestampRecommendationRequestIDGenerator(),
            virtualUserProvider: RegistryVirtualUserProvider(),
            installIdentityStore: UserDefaultsInstallIdentityStore(),
            topK: 3
        )
    }

    public static func live(baseURL: URL = URL(string: "http://127.0.0.1:8000")!) -> DependencyContainer {
        DependencyContainer(
            sensorAcquirer: SystemBaselineRawSensorAcquirer(),
            contextDeriver: VirtualContextDeriver(),
            payloadMapper: BackendPayloadMapper(),
            apiClient: LiveRecommendationAPIClient(baseURL: baseURL),
            feedbackQueue: FeedbackRetryQueue(),
            requestIDGenerator: DefaultRecommendationRequestIDGenerator(),
            virtualUserProvider: RegistryVirtualUserProvider(),
            installIdentityStore: UserDefaultsInstallIdentityStore(),
            topK: 3
        )
    }

    public func makeRunCoordinator() -> RunCoordinator {
        RunCoordinator(
            sensorAcquirer: sensorAcquirer,
            contextDeriver: contextDeriver,
            payloadMapper: payloadMapper,
            apiClient: apiClient,
            feedbackQueue: feedbackQueue,
            requestIDGenerator: requestIDGenerator,
            topK: topK
        )
    }
}
