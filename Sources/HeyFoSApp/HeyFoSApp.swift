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
        .defaultSize(width: 1140, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            FileMenuCommands()
            StackMenuCommands()
            OptionsMenuCommands()
        }
    }
}

// MARK: - File menu additions
struct FileMenuCommands: Commands {
    @FocusedObject var state: ProcessingState?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Files…") {
                state?.showAddFilesPanel()
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(state == nil)

            Button("Add Folder…") {
                state?.showAddFolderPanel()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(state == nil)

            Divider()

            Button("Save Output Image…") {
                guard let url = state?.outputImages.last?.url else { return }
                let save = NSSavePanel()
                save.nameFieldStringValue = url.lastPathComponent
                save.allowedContentTypes = [.tiff]
                save.begin { resp in
                    guard resp == .OK, let dest = save.url else { return }
                    try? FileManager.default.copyItem(at: url, to: dest)
                }
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(state?.outputImages.isEmpty != false)
        }
    }
}

// MARK: - Stack menu (mirrors ZereneStacker's Stack menu)
struct StackMenuCommands: Commands {
    @FocusedObject var state: ProcessingState?

    var body: some Commands {
        CommandMenu("Stack") {
            Button("Align & Stack All (PMax)") {
                state?.startStackingPMax()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(notReady)

            Button("Align & Stack All (DMap)") {
                state?.startStackingDMap()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(notReady)

            Divider()

            Button("Cancel Processing") {
                state?.cancelProcessing()
            }
            .disabled(state?.isProcessing != true)
        }
    }

    private var notReady: Bool {
        state == nil || state?.imageFiles.isEmpty == true || state?.isProcessing == true
    }
}

// MARK: - Options menu (mirrors ZereneStacker's Options menu)
struct OptionsMenuCommands: Commands {
    @FocusedObject var state: ProcessingState?

    var body: some Commands {
        CommandMenu("Options") {
            Button("Preferences…") {
                state?.showPreferences = true
            }
            .keyboardShortcut(",", modifiers: [.command])
            .disabled(state == nil)

            Divider()

            Button("Restore Default Layout") {
                // Layout restore is handled by resetting the window
            }

            Divider()

            Button("Clear All") {
                state?.clearAll()
            }
            .disabled(state == nil || state?.imageFiles.isEmpty == true)
        }
    }
}

// MARK: - App delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

