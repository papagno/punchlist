import Sparkle
import SwiftUI

@main
struct PunchlistApp: App {
    @State private var store = IssuesStore()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    var body: some Scene {
        Window("Punchlist", id: "main") {
            ContentView()
                .environment(store)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            SidebarCommands()
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: updaterController.updater)
            }
            // Every toolbar action is also in the menu bar (HIG: Toolbars > macOS).
            CommandGroup(replacing: .newItem) {
                Button("New Issue") { store.requestNewIssue() }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .textEditing) {
                Button("Find") { store.wantsSearchFocus = true }
                    .keyboardShortcut("f")
            }
            CommandGroup(before: .sidebar) {
                ForEach(Array(ItemKind.allCases.enumerated()), id: \.element) { index, kind in
                    Toggle(kind.rawValue, isOn: Binding(
                        get: { store.kind == kind },
                        set: { if $0 { store.kind = kind } }
                    ))
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
                Divider()
                Button("Refresh") { Task { await store.load() } }
                    .keyboardShortcut("r")
                    .disabled(store.isLoading)
                Button("Back") { withAnimation(.smooth(duration: 0.3)) { store.selection = nil } }
                    .keyboardShortcut("[")
                    .disabled(!store.isCompact || store.selection == nil)
                Divider()
            }
            CommandMenu(store.kind == .issues ? "Issue" : "Pull Request") {
                if let issue = store.selectedIssue {
                    ItemActions(issue: issue)
                        .environment(store)
                } else {
                    Button("Open in Browser") {}.disabled(true)
                    Button("Copy Link") {}.disabled(true)
                }
            }
        }
    }
}
