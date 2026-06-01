import Foundation

public struct RecoPOCRuntimeMode: Sendable {
  public let sensorAcquirer: any RawSensorAcquiring
  public let permissionCapabilityStatusProvider: any PermissionCapabilityStatusProviding

  public init(
    sensorAcquirer: any RawSensorAcquiring,
    permissionCapabilityStatusProvider: any PermissionCapabilityStatusProviding
  ) {
    self.sensorAcquirer = sensorAcquirer
    self.permissionCapabilityStatusProvider = permissionCapabilityStatusProvider
  }

  public static func baseline() -> RecoPOCRuntimeMode {
    RecoPOCRuntimeMode(
      sensorAcquirer: SystemBaselineRawSensorAcquirer(),
      permissionCapabilityStatusProvider: BaselinePermissionCapabilityStatusProvider()
    )
  }

  public static func nativeCapable(
    permissionCapabilityStatusProvider: any PermissionCapabilityStatusProviding =
      NativeCapablePermissionCapabilityStatusProvider()
  ) -> RecoPOCRuntimeMode {
    RecoPOCRuntimeMode(
      sensorAcquirer: NativeCapableRawSensorAcquirer(),
      permissionCapabilityStatusProvider: permissionCapabilityStatusProvider
    )
  }
}

public struct DependencyContainer: Sendable {
  public var sensorAcquirer: any RawSensorAcquiring
  public var contextDeriver: VirtualContextDeriving
  public var payloadMapper: BackendPayloadMapping
  public var apiClient: any RecommendationAPIClient
  public var feedbackQueue: FeedbackRetryQueue
  public var requestIDGenerator: any RecommendationRequestIDGenerating
  public var virtualUserProvider: any VirtualUserProviding
  public var installIdentityStore: any InstallIdentityStoring
  public var permissionCapabilityStatusProvider: any PermissionCapabilityStatusProviding
  public var topK: Int

  public init(
    runtimeMode: RecoPOCRuntimeMode,
    contextDeriver: VirtualContextDeriving,
    payloadMapper: BackendPayloadMapping,
    apiClient: any RecommendationAPIClient,
    feedbackQueue: FeedbackRetryQueue,
    requestIDGenerator: any RecommendationRequestIDGenerating =
      DefaultRecommendationRequestIDGenerator(),
    virtualUserProvider: any VirtualUserProviding = RegistryVirtualUserProvider(),
    installIdentityStore: any InstallIdentityStoring = UserDefaultsInstallIdentityStore(),
    topK: Int = 3
  ) {
    self.sensorAcquirer = runtimeMode.sensorAcquirer
    self.contextDeriver = contextDeriver
    self.payloadMapper = payloadMapper
    self.apiClient = apiClient
    self.feedbackQueue = feedbackQueue
    self.requestIDGenerator = requestIDGenerator
    self.virtualUserProvider = virtualUserProvider
    self.installIdentityStore = installIdentityStore
    self.permissionCapabilityStatusProvider = runtimeMode.permissionCapabilityStatusProvider
    self.topK = topK
  }

  public static func demo() -> DependencyContainer {
    DependencyContainer(
      runtimeMode: RecoPOCRuntimeMode(
        sensorAcquirer: FakeRawSensorAcquirer(result: .success(.sampleFullPermission)),
        permissionCapabilityStatusProvider: BaselinePermissionCapabilityStatusProvider()
      ),
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

  public static func baselineLive(baseURL: URL = URL(string: "http://127.0.0.1:8000")!)
    -> DependencyContainer
  {
    DependencyContainer(
      runtimeMode: .baseline(),
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

  public static func nativeCapableLive(
    baseURL: URL = URL(string: "http://127.0.0.1:8000")!,
    permissionCapabilityStatusProvider: any PermissionCapabilityStatusProviding =
      NativeCapablePermissionCapabilityStatusProvider()
  ) -> DependencyContainer {
    DependencyContainer(
      runtimeMode: .nativeCapable(permissionCapabilityStatusProvider: permissionCapabilityStatusProvider),
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

  @available(*, deprecated, renamed: "baselineLive(baseURL:)")
  public static func live(baseURL: URL = URL(string: "http://127.0.0.1:8000")!)
    -> DependencyContainer
  {
    baselineLive(baseURL: baseURL)
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
