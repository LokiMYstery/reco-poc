import Foundation

#if os(iOS) && canImport(AVFAudio)
import AVFAudio
#endif

#if os(iOS) && canImport(CoreLocation)
import CoreLocation
#endif

#if os(iOS) && canImport(CoreMotion)
import CoreMotion
#endif

#if os(iOS) && canImport(EventKit)
import EventKit
#endif

#if os(iOS) && canImport(HealthKit)
import HealthKit
#endif

public enum PermissionCapabilityReadiness: String, Sendable {
  case available = "Available"
  case limited = "Limited"
  case blocked = "Blocked"
  case requiresHost = "Requires Host"
  case optional = "Optional"
}

public struct PermissionCapabilityStatus: Equatable, Sendable {
  public var id: String
  public var statusText: String
  public var detailText: String?
  public var readiness: PermissionCapabilityReadiness

  public init(
    id: String,
    statusText: String,
    detailText: String? = nil,
    readiness: PermissionCapabilityReadiness
  ) {
    self.id = id
    self.statusText = statusText
    self.detailText = detailText
    self.readiness = readiness
  }
}

public struct SetupCapabilityGateStatus: Equatable, Sendable {
  public var title: String
  public var summary: String
  public var detail: String
  public var readiness: PermissionCapabilityReadiness

  public init(
    title: String, summary: String, detail: String, readiness: PermissionCapabilityReadiness
  ) {
    self.title = title
    self.summary = summary
    self.detail = detail
    self.readiness = readiness
  }
}

public struct PermissionCapabilityStatusSnapshot: Equatable, Sendable {
  public var gate: SetupCapabilityGateStatus
  public var permissions: [PermissionCapabilityStatus]

  public init(gate: SetupCapabilityGateStatus, permissions: [PermissionCapabilityStatus]) {
    self.gate = gate
    self.permissions = permissions
  }
}

public protocol PermissionCapabilityStatusProviding: Sendable {
  func snapshot() -> PermissionCapabilityStatusSnapshot
  func maintenanceLabel(for permissionID: String) -> String
  func requestMaintenance(for permissionID: String) async -> PermissionCapabilityStatus
}

public extension PermissionCapabilityStatusProviding {
  func requestMaintenance(for permissionID: String) async -> PermissionCapabilityStatus {
    snapshot().permissions.first { $0.id == permissionID } ?? PermissionCapabilityStatus(
      id: permissionID,
      statusText: "Unknown permission group",
      detailText: "No setup maintenance action is registered for this permission group.",
      readiness: .optional
    )
  }
}

public struct BaselinePermissionCapabilityStatusProvider: PermissionCapabilityStatusProviding {
  public init() {}

  public func snapshot() -> PermissionCapabilityStatusSnapshot {
    PermissionCapabilityStatusSnapshot(
      gate: SetupCapabilityGateStatus(
        title: "Phase 0 host gate: package-only baseline",
        summary:
          "Baseline-safe run path is available; entitlement-backed permissions remain blocked.",
        detail:
          "This SwiftPM package can run the recommendation baseline today, but location, motion, HealthKit, microphone, calendar, WeatherKit, and similar device permission flows require a native host before they can be verified on device.",
        readiness: .requiresHost
      ),
      permissions: [
        .init(
          id: "location", statusText: "Blocked by package-only host",
          detailText: "Needs Info.plist usage strings and on-device permission flow.",
          readiness: .requiresHost),
        .init(
          id: "motion", statusText: "Blocked by package-only host",
          detailText: "Motion/Fitness permission validation is deferred until a host app exists.",
          readiness: .requiresHost),
        .init(
          id: "health", statusText: "Blocked by package-only host",
          detailText:
            "HealthKit entitlement and read/share scopes are not available in the baseline package.",
          readiness: .requiresHost),
        .init(
          id: "microphone", statusText: "Blocked by package-only host",
          detailText: "Microphone permission prompting and capture verification need a host app.",
          readiness: .requiresHost),
        .init(
          id: "calendar", statusText: "Blocked by package-only host",
          detailText: "EventKit access must be validated through a host app.",
          readiness: .requiresHost),
        .init(
          id: "weather", statusText: "Blocked by package-only host",
          detailText: "WeatherKit requires a signed host entitlement; it has no user prompt sheet.",
          readiness: .requiresHost),
        .init(
          id: "audio_route", statusText: "Available in baseline",
          detailText: "Low-permission audio route status can stay package-first.",
          readiness: .available),
        .init(
          id: "network", statusText: "Available in baseline",
          detailText: "Low-permission network status can stay package-first.", readiness: .available
        ),
        .init(
          id: "questionnaire", statusText: "Optional app input",
          detailText: "Questionnaire remains editable without native permission work.",
          readiness: .optional),
      ]
    )
  }

  public func maintenanceLabel(for permissionID: String) -> String {
    switch permissionID {
    case "audio_route", "network", "questionnaire":
      return "Inspect baseline"
    default:
      return "Host required"
    }
  }

  public func requestMaintenance(for permissionID: String) async -> PermissionCapabilityStatus {
    snapshot().permissions.first { $0.id == permissionID } ?? PermissionCapabilityStatus(
      id: permissionID,
      statusText: "Host required",
      detailText: "The package baseline has no system permission request surface.",
      readiness: .requiresHost
    )
  }
}

public final class NativeCapablePermissionCapabilityStatusProvider:
  PermissionCapabilityStatusProviding, @unchecked Sendable
{
  #if os(iOS) && canImport(CoreLocation)
  private let locationRequester = LocationPermissionRequester()
  #endif

  #if os(iOS) && canImport(CoreMotion)
  private let motionRequester = MotionPermissionRequester()
  #endif

  public init() {}

  public func snapshot() -> PermissionCapabilityStatusSnapshot {
    let permissions = [
      locationStatus(),
      motionStatus(),
      healthStatus(),
      microphoneStatus(),
      calendarStatus(),
      weatherStatus(),
      audioRouteStatus(),
      networkStatus(),
      questionnaireStatus(),
    ]

    return PermissionCapabilityStatusSnapshot(
      gate: SetupCapabilityGateStatus(
        title: "Native host permission gate: device prompts enabled",
        summary: "This host target owns privacy strings, entitlements, and setup-triggered permission requests.",
        detail:
          "Tap Check / Request in Setup to invoke system authorization sheets. Recommendation runs stay prompt-free and only read whatever setup already allowed.",
        readiness: gateReadiness(from: permissions)
      ),
      permissions: permissions
    )
  }

  public func maintenanceLabel(for permissionID: String) -> String {
    switch permissionID {
    case "location", "motion", "health", "microphone", "calendar":
      return "Requesting system permission…"
    case "weather":
      return "Checking entitlement-only service…"
    case "audio_route", "network", "questionnaire":
      return "Inspecting low-permission signal…"
    default:
      return "Inspecting…"
    }
  }

  public func requestMaintenance(for permissionID: String) async -> PermissionCapabilityStatus {
    switch permissionID {
    case "location":
      return await requestLocationPermission()
    case "motion":
      return await requestMotionPermission()
    case "health":
      return await requestHealthPermission()
    case "microphone":
      return await requestMicrophonePermission()
    case "calendar":
      return await requestCalendarPermission()
    case "weather":
      return weatherStatus(requested: true)
    case "audio_route":
      return audioRouteStatus(requested: true)
    case "network":
      return networkStatus(requested: true)
    case "questionnaire":
      return questionnaireStatus(requested: true)
    default:
      return PermissionCapabilityStatus(
        id: permissionID,
        statusText: "Unknown permission group",
        detailText: "No native maintenance action is registered for this permission group.",
        readiness: .optional
      )
    }
  }

  private func gateReadiness(from permissions: [PermissionCapabilityStatus]) -> PermissionCapabilityReadiness {
    if permissions.contains(where: { $0.readiness == .blocked || $0.readiness == .requiresHost }) {
      return .limited
    }
    if permissions.contains(where: { $0.readiness == .limited }) {
      return .limited
    }
    return .available
  }

  #if os(iOS) && canImport(CoreLocation)
  private func locationStatus(
    override statusOverride: CLAuthorizationStatus? = nil,
    requested: Bool = false
  ) -> PermissionCapabilityStatus {
    guard CLLocationManager.locationServicesEnabled() else {
      return PermissionCapabilityStatus(
        id: "location",
        statusText: "Location Services disabled",
        detailText: "Enable Location Services in Settings before this app can request When-In-Use access.",
        readiness: .blocked
      )
    }

    let manager = CLLocationManager()
    let status = statusOverride ?? manager.authorizationStatus
    switch status {
    case .notDetermined:
      return PermissionCapabilityStatus(
        id: "location",
        statusText: requested ? "Location request still pending" : "Not requested",
        detailText: "Tap Check / Request to show the iOS When-In-Use location prompt.",
        readiness: .limited
      )
    case .restricted:
      return PermissionCapabilityStatus(
        id: "location",
        statusText: "Restricted by system policy",
        detailText: "iOS restrictions prevent this app from accessing location.",
        readiness: .blocked
      )
    case .denied:
      return PermissionCapabilityStatus(
        id: "location",
        statusText: "Denied",
        detailText: "Change this app's Location setting in iOS Settings to allow place context.",
        readiness: .blocked
      )
    case .authorizedWhenInUse, .authorizedAlways:
      let accuracy = manager.accuracyAuthorization == .fullAccuracy ? "Precise" : "Approximate"
      return PermissionCapabilityStatus(
        id: "location",
        statusText: "Authorized (\(accuracy))",
        detailText: "Location can be sampled during setup/run acquisition without prompting again.",
        readiness: manager.accuracyAuthorization == .fullAccuracy ? .available : .limited
      )
    @unknown default:
      return PermissionCapabilityStatus(
        id: "location",
        statusText: "Unknown location status",
        detailText: "iOS returned an unrecognized CoreLocation authorization state.",
        readiness: .limited
      )
    }
  }
  #else
  private func locationStatus(requested: Bool = false) -> PermissionCapabilityStatus {
    PermissionCapabilityStatus(
      id: "location",
      statusText: "iOS host required",
      detailText: "CoreLocation prompting is only wired in the iOS host target.",
      readiness: .requiresHost
    )
  }
  #endif

  private func requestLocationPermission() async -> PermissionCapabilityStatus {
    #if os(iOS) && canImport(CoreLocation)
    let status = await locationRequester.requestWhenInUseAuthorization()
    return locationStatus(override: status, requested: true)
    #else
    return locationStatus(requested: true)
    #endif
  }

  #if os(iOS) && canImport(CoreMotion)
  private func motionStatus(
    override statusOverride: CMAuthorizationStatus? = nil,
    requested: Bool = false
  ) -> PermissionCapabilityStatus {
    guard CMMotionActivityManager.isActivityAvailable() else {
      return PermissionCapabilityStatus(
        id: "motion",
        statusText: "Motion activity unavailable",
        detailText: "This device does not expose CMMotionActivity samples for the app.",
        readiness: .blocked
      )
    }

    let status = statusOverride ?? CMMotionActivityManager.authorizationStatus()
    switch status {
    case .notDetermined:
      return PermissionCapabilityStatus(
        id: "motion",
        statusText: requested ? "Motion request started" : "Not requested",
        detailText: "iOS shows Motion & Fitness when the app first queries motion activity.",
        readiness: .limited
      )
    case .restricted:
      return PermissionCapabilityStatus(
        id: "motion",
        statusText: "Restricted by system policy",
        detailText: "iOS restrictions prevent Motion & Fitness access.",
        readiness: .blocked
      )
    case .denied:
      return PermissionCapabilityStatus(
        id: "motion",
        statusText: "Denied",
        detailText: "Change Motion & Fitness for this app in iOS Settings if you want activity context.",
        readiness: .blocked
      )
    case .authorized:
      return PermissionCapabilityStatus(
        id: "motion",
        statusText: "Authorized",
        detailText: "Motion activity can be queried for coarse activity context.",
        readiness: .available
      )
    @unknown default:
      return PermissionCapabilityStatus(
        id: "motion",
        statusText: "Unknown motion status",
        detailText: "iOS returned an unrecognized CoreMotion authorization state.",
        readiness: .limited
      )
    }
  }
  #else
  private func motionStatus(requested: Bool = false) -> PermissionCapabilityStatus {
    PermissionCapabilityStatus(
      id: "motion",
      statusText: "iOS host required",
      detailText: "CoreMotion prompting is only wired in the iOS host target.",
      readiness: .requiresHost
    )
  }
  #endif

  private func requestMotionPermission() async -> PermissionCapabilityStatus {
    #if os(iOS) && canImport(CoreMotion)
    let status = await motionRequester.requestActivityAuthorization()
    return motionStatus(override: status, requested: true)
    #else
    return motionStatus(requested: true)
    #endif
  }

  private func healthStatus(requested: Bool = false, errorMessage: String? = nil) -> PermissionCapabilityStatus {
    #if os(iOS) && canImport(HealthKit)
    guard HKHealthStore.isHealthDataAvailable() else {
      return PermissionCapabilityStatus(
        id: "health",
        statusText: "Health data unavailable",
        detailText: "HealthKit is unavailable on this device or profile.",
        readiness: .blocked
      )
    }

    if let errorMessage {
      return PermissionCapabilityStatus(
        id: "health",
        statusText: "HealthKit request failed",
        detailText: errorMessage,
        readiness: .blocked
      )
    }

    if requested || NativePermissionAttemptStore.wasRequested("health") {
      return PermissionCapabilityStatus(
        id: "health",
        statusText: "HealthKit request completed",
        detailText: "iOS does not reveal read-grant state to apps; verify allowed types in Health > Sharing > Apps.",
        readiness: .limited
      )
    }

    return PermissionCapabilityStatus(
      id: "health",
      statusText: "Not requested",
      detailText: "Tap Check / Request to ask for read access to heart rate, steps, active energy, and sleep.",
      readiness: .limited
    )
    #else
    return PermissionCapabilityStatus(
      id: "health",
      statusText: "iOS host required",
      detailText: "HealthKit prompting is only wired in the iOS host target.",
      readiness: .requiresHost
    )
    #endif
  }

  private func requestHealthPermission() async -> PermissionCapabilityStatus {
    #if os(iOS) && canImport(HealthKit)
    guard HKHealthStore.isHealthDataAvailable() else { return healthStatus(requested: true) }
    let readTypes = Self.healthReadTypes()
    guard !readTypes.isEmpty else {
      return PermissionCapabilityStatus(
        id: "health",
        statusText: "HealthKit types unavailable",
        detailText: "The configured HealthKit read types are not available on this SDK/device.",
        readiness: .blocked
      )
    }

    let result = await withCheckedContinuation { continuation in
      HKHealthStore().requestAuthorization(toShare: [], read: readTypes) { success, error in
        continuation.resume(returning: (success, error?.localizedDescription))
      }
    }

    if result.0 {
      NativePermissionAttemptStore.markRequested("health")
      return healthStatus(requested: true)
    }
    return healthStatus(requested: true, errorMessage: result.1 ?? "HealthKit did not complete authorization.")
    #else
    return healthStatus(requested: true)
    #endif
  }

  private func microphoneStatus(
    override grantedOverride: Bool? = nil,
    requested: Bool = false
  ) -> PermissionCapabilityStatus {
    #if os(iOS) && canImport(AVFAudio)
    if let grantedOverride {
      return PermissionCapabilityStatus(
        id: "microphone",
        statusText: grantedOverride ? "Authorized" : "Denied",
        detailText: grantedOverride
          ? "Microphone can be sampled locally for ambient-noise classification."
          : "Change this app's Microphone setting in iOS Settings to allow ambient-noise context.",
        readiness: grantedOverride ? .available : .blocked
      )
    }

    switch AVAudioApplication.shared.recordPermission {
    case .undetermined:
      return PermissionCapabilityStatus(
        id: "microphone",
        statusText: requested ? "Microphone request still pending" : "Not requested",
        detailText: "Tap Check / Request to show the iOS microphone prompt.",
        readiness: .limited
      )
    case .denied:
      return PermissionCapabilityStatus(
        id: "microphone",
        statusText: "Denied",
        detailText: "Change this app's Microphone setting in iOS Settings to allow ambient-noise context.",
        readiness: .blocked
      )
    case .granted:
      return PermissionCapabilityStatus(
        id: "microphone",
        statusText: "Authorized",
        detailText: "Microphone can be sampled locally for ambient-noise classification.",
        readiness: .available
      )
    @unknown default:
      return PermissionCapabilityStatus(
        id: "microphone",
        statusText: "Unknown microphone status",
        detailText: "iOS returned an unrecognized AVAudio authorization state.",
        readiness: .limited
      )
    }
    #else
    return PermissionCapabilityStatus(
      id: "microphone",
      statusText: "iOS host required",
      detailText: "Microphone prompting is only wired in the iOS host target.",
      readiness: .requiresHost
    )
    #endif
  }

  private func requestMicrophonePermission() async -> PermissionCapabilityStatus {
    #if os(iOS) && canImport(AVFAudio)
    let granted = await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
    return microphoneStatus(override: granted, requested: true)
    #else
    return microphoneStatus(requested: true)
    #endif
  }

  #if os(iOS) && canImport(EventKit)
  private func calendarStatus(
    override statusOverride: EKAuthorizationStatus? = nil,
    requested: Bool = false,
    errorMessage: String? = nil
  ) -> PermissionCapabilityStatus {
    if let errorMessage {
      return PermissionCapabilityStatus(
        id: "calendar",
        statusText: "Calendar request failed",
        detailText: errorMessage,
        readiness: .blocked
      )
    }

    let status = statusOverride ?? EKEventStore.authorizationStatus(for: .event)
    switch status {
    case .notDetermined:
      return PermissionCapabilityStatus(
        id: "calendar",
        statusText: requested ? "Calendar request still pending" : "Not requested",
        detailText: "Tap Check / Request to show the iOS Calendar full-access prompt.",
        readiness: .limited
      )
    case .restricted:
      return PermissionCapabilityStatus(
        id: "calendar",
        statusText: "Restricted by system policy",
        detailText: "iOS restrictions prevent calendar access.",
        readiness: .blocked
      )
    case .denied:
      return PermissionCapabilityStatus(
        id: "calendar",
        statusText: "Denied",
        detailText: "Change this app's Calendar setting in iOS Settings to allow event-keyword context.",
        readiness: .blocked
      )
    case .fullAccess:
      return PermissionCapabilityStatus(
        id: "calendar",
        statusText: "Full access authorized",
        detailText: "Calendar can be read locally and reduced to coarse keywords before upload.",
        readiness: .available
      )
    case .writeOnly:
      return PermissionCapabilityStatus(
        id: "calendar",
        statusText: "Write-only access",
        detailText: "RecoPOC needs full read access for calendar-keyword context; write-only is insufficient.",
        readiness: .limited
      )
    @unknown default:
      return PermissionCapabilityStatus(
        id: "calendar",
        statusText: "Unknown calendar status",
        detailText: "iOS returned an unrecognized EventKit authorization state.",
        readiness: .limited
      )
    }
  }
  #else
  private func calendarStatus(requested: Bool = false, errorMessage: String? = nil) -> PermissionCapabilityStatus {
    PermissionCapabilityStatus(
      id: "calendar",
      statusText: errorMessage == nil ? "iOS host required" : "Calendar request failed",
      detailText: errorMessage ?? "EventKit prompting is only wired in the iOS host target.",
      readiness: .requiresHost
    )
  }
  #endif

  private func requestCalendarPermission() async -> PermissionCapabilityStatus {
    #if os(iOS) && canImport(EventKit)
    let result = await withCheckedContinuation { continuation in
      EKEventStore().requestFullAccessToEvents { granted, error in
        continuation.resume(returning: (granted, error?.localizedDescription))
      }
    }
    if let error = result.1 {
      return calendarStatus(requested: true, errorMessage: error)
    }
    return calendarStatus(
      override: result.0 ? .fullAccess : EKEventStore.authorizationStatus(for: .event),
      requested: true
    )
    #else
    return calendarStatus(requested: true)
    #endif
  }

  private func weatherStatus(requested: Bool = false) -> PermissionCapabilityStatus {
    PermissionCapabilityStatus(
      id: "weather",
      statusText: "No user prompt",
      detailText: requested
        ? "WeatherKit is entitlement/service-gated, not user-authorized. This host carries the WeatherKit entitlement; service failures will appear when weather reads are implemented."
        : "WeatherKit does not show an iOS permission sheet; it depends on signing, entitlement, and Apple service availability.",
      readiness: .available
    )
  }

  private func audioRouteStatus(requested: Bool = false) -> PermissionCapabilityStatus {
    PermissionCapabilityStatus(
      id: "audio_route",
      statusText: "Available",
      detailText: requested
        ? "Audio route inspection does not require a separate iOS prompt."
        : "No additional host entitlement needed for baseline audio-route status.",
      readiness: .available
    )
  }

  private func networkStatus(requested: Bool = false) -> PermissionCapabilityStatus {
    PermissionCapabilityStatus(
      id: "network",
      statusText: "Available",
      detailText: requested
        ? "Network path inspection does not require a separate iOS prompt."
        : "No additional host entitlement needed for baseline network status.",
      readiness: .available
    )
  }

  private func questionnaireStatus(requested: Bool = false) -> PermissionCapabilityStatus {
    PermissionCapabilityStatus(
      id: "questionnaire",
      statusText: "Optional app input",
      detailText: requested
        ? "Use the questionnaire controls below; no system authorization is involved."
        : "Questionnaire remains independent from permission prompting.",
      readiness: .optional
    )
  }

  #if os(iOS) && canImport(HealthKit)
  private static func healthReadTypes() -> Set<HKObjectType> {
    var types = Set<HKObjectType>()
    if let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate) {
      types.insert(heartRate)
    }
    if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) {
      types.insert(steps)
    }
    if let activeEnergy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
      types.insert(activeEnergy)
    }
    if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
      types.insert(sleep)
    }
    return types
  }
  #endif
}

private enum NativePermissionAttemptStore {
  private static let prefix = "RecoPOC.nativePermissionAttempt."

  static func wasRequested(_ permissionID: String) -> Bool {
    UserDefaults.standard.bool(forKey: prefix + permissionID)
  }

  static func markRequested(_ permissionID: String) {
    UserDefaults.standard.set(true, forKey: prefix + permissionID)
  }
}

#if os(iOS) && canImport(CoreLocation)
private final class LocationPermissionRequester: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
  private let manager = CLLocationManager()
  private var pendingContinuation: SingleResumeBox<CLAuthorizationStatus>?

  override init() {
    super.init()
    manager.delegate = self
  }

  func requestWhenInUseAuthorization() async -> CLAuthorizationStatus {
    await withCheckedContinuation { continuation in
      let box = SingleResumeBox(continuation)
      Task { @MainActor in
        self.startWhenInUseAuthorization(box)
      }
    }
  }

  @MainActor
  private func startWhenInUseAuthorization(_ box: SingleResumeBox<CLAuthorizationStatus>) {
    guard CLLocationManager.locationServicesEnabled() else {
      box.resume(returning: manager.authorizationStatus)
      return
    }

    let status = manager.authorizationStatus
    guard status == .notDetermined else {
      box.resume(returning: status)
      return
    }

    pendingContinuation?.resume(returning: status)
    pendingContinuation = box
    manager.requestWhenInUseAuthorization()

    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak box] in
      guard let self, let box else { return }
      box.resume(returning: self.manager.authorizationStatus)
      if self.pendingContinuation === box {
        self.pendingContinuation = nil
      }
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    guard status != .notDetermined else { return }
    pendingContinuation?.resume(returning: status)
    pendingContinuation = nil
  }
}
#endif

#if os(iOS) && canImport(CoreMotion)
private final class MotionPermissionRequester: @unchecked Sendable {
  private let manager = CMMotionActivityManager()

  func requestActivityAuthorization() async -> CMAuthorizationStatus {
    guard CMMotionActivityManager.isActivityAvailable() else {
      return CMMotionActivityManager.authorizationStatus()
    }

    let status = CMMotionActivityManager.authorizationStatus()
    guard status == .notDetermined else { return status }

    return await withCheckedContinuation { continuation in
      let box = SingleResumeBox(continuation)
      let endDate = Date()
      manager.queryActivityStarting(from: endDate.addingTimeInterval(-60), to: endDate, to: .main) { _, _ in
        box.resume(returning: CMMotionActivityManager.authorizationStatus())
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        box.resume(returning: CMMotionActivityManager.authorizationStatus())
      }
    }
  }
}
#endif

#if os(iOS)
private final class SingleResumeBox<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Never>?

  init(_ continuation: CheckedContinuation<Value, Never>) {
    self.continuation = continuation
  }

  func resume(returning value: Value) {
    lock.lock()
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(returning: value)
  }
}
#endif
