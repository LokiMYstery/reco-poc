import SwiftUI

public struct RecoPOCApp: App {
    @StateObject private var model: DemoRecoPOCAppModel

    public init() {
        _model = StateObject(wrappedValue: DemoRecoPOCAppModel(container: .live()))
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
