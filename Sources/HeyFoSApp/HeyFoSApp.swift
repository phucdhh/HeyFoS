import SwiftUI
import AppKit

@main
struct HeyFoSDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("HeyFoS") {
            ContentView()
                .frame(minWidth: 820, minHeight: 540)
        }
        .defaultSize(width: 980, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
