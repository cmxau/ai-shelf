import SwiftUI

@main struct AIShelf: App {
    @ObservedObject var m = Model.shared
    @Environment(\.openWindow) var openWindow
    @AppStorage("cli") var cli = "claude"
    @AppStorage("terminal") var terminal = "Terminal"
    @AppStorage("showCards") var showCards = true
    @AppStorage("autoReload") var autoReload = false
    @AppStorage("trashDelete") var trashDelete = true
    var body: some Scene { scenes.commands { commandItems } }

    @SceneBuilder var scenes: some Scene {
        Window("AI Shelf", id: "main") { ContentView().frame(minWidth: 820, minHeight: 580) }
        MenuBarExtra("AI Shelf", systemImage: "books.vertical") { MenuView() }
        Window("Usage Stats", id: "stats") { StatsView() }
        Settings { SettingsView() }
    }

    @CommandsBuilder var commandItems: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About AI Shelf") {
                NSApp.orderFrontStandardAboutPanel(options: [.credits: NSAttributedString(string: "Browse, resume and clean up AI coding agent sessions.")])
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Check for Updates…") {
                Updater.shared.check(); showSettings()
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("Open in Terminal") { m.openSelected() }.keyboardShortcut(.return, modifiers: .command).disabled(m.selection.isEmpty)
            Button("Show in Finder") { m.revealSelected() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(m.selection.isEmpty)
            Button("Copy Path") { m.copySelected() }.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(m.selection.isEmpty)
            Button("Fix Path…") { m.fixSelected() }.keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(m.selection.isEmpty || cli != "claude")
            Divider()
            Button("Export Statistics…") { exportStatsPanel() }
            Button("Import Statistics…") { importStatsPanel() }
        }
        CommandMenu("Session") {
            Button("Delete…") { m.ask(m.selection) }.keyboardShortcut(.delete, modifiers: .command).disabled(m.selection.isEmpty)
            Button("Delete Missing…") { m.request(m.projects.filter { !$0.exists }) }.disabled(m.projects.allSatisfy(\.exists))
            Button("Undo Delete") { m.undo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(m.undos.isEmpty)
            Divider()
            Button("Pin / Unpin") { m.togglePin() }.keyboardShortcut("d", modifiers: .command).disabled(m.selection.isEmpty)
            Button("Edit Note…") { m.editNote() }.keyboardShortcut("e", modifiers: .command).disabled(m.selection.isEmpty)
            Button("Export as Markdown…") { m.exportSelected() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(m.selection.isEmpty)
            Menu("Clean Up") {
                Button("Delete Empty Sessions…") { m.cleanUp(olderThan: nil) }
                Button("Delete Sessions Older Than 30 Days…") { m.cleanUp(olderThan: 30) }
                Button("Delete Sessions Older Than 90 Days…") { m.cleanUp(olderThan: 90) }
                Button("Delete Sessions Older Than 180 Days…") { m.cleanUp(olderThan: 180) }
            }
            Divider()
            Button("Reload") { m.reload() }.keyboardShortcut("r", modifiers: .command)
        }
        CommandGroup(after: .toolbar) {
            Menu("Sort By") {
                ForEach(RowSort.Field.allCases, id: \.self) { f in
                    Button {
                        m.sortBy(f)
                    } label: {
                        if let c = m.sortOrder.first, c.field == f {
                            Label(f.title + (c.order == .forward ? "  ↑" : "  ↓"), systemImage: "checkmark")
                        } else {
                            Text(f.title)
                        }
                    }
                }
            }
            Picker("Agent", selection: $cli) {
                Text("All agents").tag("all"); ForEach(m.agents, id: \.self) { Text($0).tag($0) }
            }
            Picker("Terminal", selection: $terminal) { ForEach(terminals, id: \.self) { Text($0).tag($0) } }
            Divider()
            Toggle("Show Statistics Cards", isOn: $showCards)
            Toggle("Reload Automatically", isOn: $autoReload)
            Toggle("Move Deleted Items to Trash", isOn: $trashDelete)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Manager") {
                openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
            }
            Button("Usage Stats") {
                openWindow(id: "stats"); NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("u", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Button("Report a Bug…") { openIssue("bug_report.yml") }
            Button("Request a Feature…") { openIssue("feature_request.yml") }
            Button("AI Shelf on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/\(repoSlug)")!) }
        }
    }
}
