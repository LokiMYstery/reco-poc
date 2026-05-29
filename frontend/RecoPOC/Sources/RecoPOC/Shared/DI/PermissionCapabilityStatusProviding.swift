import Foundation

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
          "This SwiftPM package can run the recommendation baseline today, but location, motion, HealthKit, microphone, calendar, and similar device permission flows require a native host before they can be verified on device.",
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
}

public struct NativeCapablePermissionCapabilityStatusProvider: PermissionCapabilityStatusProviding {
  public init() {}

  public func snapshot() -> PermissionCapabilityStatusSnapshot {
    PermissionCapabilityStatusSnapshot(
      gate: SetupCapabilityGateStatus(
        title: "Phase 0 host gate: native-capable path",
        summary: "A native host can own privacy strings, entitlements, and on-device validation.",
        detail:
          "Use this path only when an embedding iOS host target is present and responsible for Info.plist usage descriptions, capabilities, and device permission flows.",
        readiness: .limited
      ),
      permissions: [
        .init(
          id: "location", statusText: "Host can validate permission",
          detailText: "Requires When-In-Use usage description and device test.", readiness: .limited
        ),
        .init(
          id: "motion", statusText: "Host can validate permission",
          detailText: "Requires Motion/Fitness description and device test.", readiness: .limited),
        .init(
          id: "health", statusText: "Host can validate entitlement",
          detailText: "Requires HealthKit capability plus share/read configuration.",
          readiness: .limited),
        .init(
          id: "microphone", statusText: "Host can validate permission",
          detailText: "Requires microphone usage description and device test.", readiness: .limited),
        .init(
          id: "calendar", statusText: "Host can validate permission",
          detailText: "Requires calendar usage description and device test.", readiness: .limited),
        .init(
          id: "audio_route", statusText: "Available",
          detailText: "No additional host entitlement needed for baseline status seam.",
          readiness: .available),
        .init(
          id: "network", statusText: "Available",
          detailText: "No additional host entitlement needed for baseline status seam.",
          readiness: .available),
        .init(
          id: "questionnaire", statusText: "Optional app input",
          detailText: "Questionnaire remains independent from permission prompting.",
          readiness: .optional),
      ]
    )
  }

  public func maintenanceLabel(for permissionID: String) -> String {
    switch permissionID {
    case "audio_route", "network", "questionnaire":
      return "Inspect host"
    default:
      return "Validate on device"
    }
  }
}
