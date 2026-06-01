import SwiftUI

public struct RecoPOCApp: App {
  @StateObject private var model: DemoRecoPOCAppModel

  public init() {
    _model = StateObject(wrappedValue: DemoRecoPOCAppModel(container: .baselineLive()))
  }

  init(container: DependencyContainer) {
    _model = StateObject(wrappedValue: DemoRecoPOCAppModel(container: container))
  }

  public var body: some Scene {
    WindowGroup {
      RecoPOCAppShell(model: model)
    }
  }
}


public struct RecoPOCAppView: View {
  @StateObject private var model: DemoRecoPOCAppModel

  public init(container: DependencyContainer = .baselineLive()) {
    _model = StateObject(wrappedValue: DemoRecoPOCAppModel(container: container))
  }

  public var body: some View {
    RecoPOCAppShell(model: model)
  }
}
