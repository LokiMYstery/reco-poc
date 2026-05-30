import RecoPOC
import SwiftUI

@main
struct RecoPOCHostApp: App {
    var body: some Scene {
        WindowGroup {
            RecoPOCAppView(container: .nativeCapableLive(baseURL: HostConfiguration.backendBaseURL))
        }
    }
}
