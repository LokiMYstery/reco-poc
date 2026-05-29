import RecoPOC
import SwiftUI

@main
struct RecoPOCHostApp: App {
    var body: some Scene {
        WindowGroup {
            RecoPOCAppView(container: .baselineLive(baseURL: HostConfiguration.backendBaseURL))
        }
    }
}
