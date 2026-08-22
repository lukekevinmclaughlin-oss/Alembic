import SwiftUI
#if os(macOS)
import AppKit

// Alembic is a single-window app. The main window is a `Window` scene with a stable
// id, so SwiftUI lists it in the Window menu and it can always be reopened after the
// user clicks the red close button. `MainWindowCommand` below adds an explicit
// "Alembic Window" item (⌘0) to that menu as well, and clicking the Dock icon
// reopens the window too. This satisfies Guideline 4: the app is never left running
// with no way to get its window back.
final class AlembicAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Returning true lets AppKit/SwiftUI restore the `Window` scene when the
        // Dock icon is clicked with no window on screen.
        true
    }
}

/// Lives in the Window menu so the main window can be restored after it is closed.
private struct MainWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Alembic Window") { openWindow(id: AlembicApp.mainWindowID) }
            .keyboardShortcut("0", modifiers: .command)
    }
}
#endif

@main
struct AlembicApp: App {
    #if os(macOS)
    static let mainWindowID = "alembic.main"
    @NSApplicationDelegateAdaptor(AlembicAppDelegate.self) private var appDelegate
    #endif
    @State private var model = AppModel()

    var body: some Scene {
        #if os(macOS)
        Window("Alembic", id: Self.mainWindowID) {
            ContentView()
                .environment(model)
                .environmentObject(PurchaseManager.shared)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .windowList) {
                MainWindowCommand()
            }
            CommandGroup(after: .undoRedo) {
                Button("Undo Pipeline Edit") { model.undo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canUndo || !model.hasProject)
                Button("Redo Pipeline Edit") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .option, .shift])
                    .disabled(!model.canRedo || !model.hasProject)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project") { model.reset() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            // Run / cancel + screen navigation
            CommandMenu("Pipeline") {
                Button(model.isRunningFull ? "Cancel Run" : "Run Full Pipeline") {
                    if model.isRunningFull { model.cancelFull() } else { model.runFull() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.hasProject || (model.ops.isEmpty && !model.isRunningFull))

                Divider()
                ForEach(Array(AppScreen.allCases.enumerated()), id: \.element) { i, screen in
                    Button(screen.title) { model.screen = screen }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                        .disabled(!model.hasProject)
                }
            }
        }
        #else
        WindowGroup {
            ContentView()
                .environment(model)
                .environmentObject(PurchaseManager.shared)
        }
        #endif
    }
}
