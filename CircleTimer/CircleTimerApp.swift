import SwiftUI

@main
struct CircleTimerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // All UI is managed by the menu bar and a borderless floating NSPanel.
        Settings {
            EmptyView()
        }
    }
}
