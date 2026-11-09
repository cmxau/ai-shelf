import SwiftUI
import UniformTypeIdentifiers

struct AboutView: View {
    @ObservedObject var u = Updater.shared
    @AppStorage(Pref.autoCheckUpdates) var autoCheck = true
    @AppStorage(Pref.autoInstallUpdates) var autoInstall = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
                Text("AI Shelf").font(.title.weight(.semibold))
                Text("Version \(appVersion)").foregroundStyle(.secondary)
                Text("Browse, resume and clean up your AI coding agent sessions, and see what they cost.")
                    .multilineTextAlignment(.center).font(.callout)
                Divider().padding(.vertical, 4)
                HStack {
                    Button(u.busy ? "Working…" : "Check for Updates") { u.check() }.disabled(u.busy)
                    if u.available != nil { Button("Install Update") { u.install() }.disabled(u.busy) }
                }
                if !u.status.isEmpty { Text(u.status).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                Toggle("Check for updates automatically", isOn: $autoCheck)
                Toggle("Install updates automatically", isOn: $autoInstall).disabled(!autoCheck)
                Divider().padding(.vertical, 4)
                HStack {
                    Button("Report a Bug") { openIssue("bug_report.yml") }
                    Button("Request a Feature") { openIssue("feature_request.yml") }
                    Button("GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/\(repoSlug)")!) }
                }
                Text("Designed and developed by cmxau").font(.callout).padding(.top, 6)
                Text(
                    "Token costs are estimates from vendors' public list prices. Everything stays on this Mac; the network is used only for price pages and update checks."
                )
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("Not affiliated with Anthropic, OpenAI or Google.").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(24).frame(maxWidth: .infinity)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var m = Model.shared
    @AppStorage(Pref.defaultAgent) var defaultAgent = "claude"
    @AppStorage(Pref.defaultTerminal) var defaultTerminal = "Terminal"
    @AppStorage(Pref.openInTab) var openInTab = false
    @AppStorage(Pref.confirmDelete) var confirmDelete = true
    @AppStorage(Pref.trashDelete) var trashDelete = true
    @AppStorage(Pref.autoReload) var autoReload = false
    @AppStorage(Pref.columns) var cols = TableColumnCustomization<Project>()
    @AppStorage(Pref.menuCount) var menuCount = 10
    @AppStorage(Pref.showDock) var showDock = true
    @AppStorage(Pref.disabledAgents) var disabled = ""
    @AppStorage(Pref.customAgents) var custom = ""
    @AppStorage(Pref.agentFlags) var flags = ""
    @AppStorage(Pref.claudeRoot) var claudePath = ""
    @AppStorage(Pref.agyRoot) var agyPath = ""
    @AppStorage(Pref.codexRoot) var codexPath = ""
    @AppStorage(Pref.geminiRoot) var geminiPath = ""
    @AppStorage(Pref.calcStats) var calcStats = true
    @AppStorage(Pref.showCards) var showCards = true
    @ObservedObject var stats = StatsStore.shared
    @AppStorage(Pref.prices) var prices = ""
    @ObservedObject var book = PriceBook.shared
    @AppStorage(Pref.autoPrices) var autoPrices = true
    @AppStorage(Pref.hotkey) var hotkey = true
    @AppStorage(Pref.notify) var notifyOn = true
    @AppStorage(Pref.monthlyBudget) var budgetText = ""
    @AppStorage(Pref.syncFolder) var syncFolder = ""

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            agentsTab.tabItem { Label("Agents", systemImage: "terminal") }
            usageTab.tabItem { Label("Usage", systemImage: "chart.bar") }
            pathsTab.tabItem { Label("Paths", systemImage: "folder") }
            AboutView().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 600, height: 640)
        .onChange(of: disabled) { m.refreshAgents() }
        .onChange(of: custom) { m.refreshAgents() }
        .onChange(of: claudePath) { m.reload() }
        .onChange(of: agyPath) { m.reload() }
        .onChange(of: codexPath) { m.reload() }
        .onChange(of: geminiPath) { m.reload() }
        .onChange(of: showDock) { applyDock() }
        .onChange(of: hotkey) { HotKey.update() }
        .onChange(of: calcStats) { m.reload() }
    }

    var general: some View {
        Form {
            Section("Defaults (applied at launch)") {
                Picker("Agent", selection: $defaultAgent) {
                    Text("All agents").tag("all")
                    ForEach(m.agents, id: \.self) { Text($0).tag($0) }
                }
                Picker("Terminal", selection: $defaultTerminal) { ForEach(terminals, id: \.self) { Text($0).tag($0) } }
                Toggle("Open in a new tab (iTerm only)", isOn: $openInTab)
            }
            Section("Delete") {
                Toggle("Ask before deleting", isOn: $confirmDelete)
                Toggle("Move to Trash (turn off to delete permanently, no undo)", isOn: $trashDelete)
            }
            Section("List") {
                Text("Right-click a column header to show or hide columns; drag headers to reorder.").font(.caption).foregroundStyle(.secondary)
                Button("Reset columns") { cols = TableColumnCustomization() }
                Toggle("Reload when the app is brought to the front", isOn: $autoReload)
            }
            Section("Menu bar") {
                Stepper("Recent projects shown: \(menuCount)", value: $menuCount, in: 3...25)
                Toggle("Keep Dock icon when no window is open", isOn: $showDock)
                Toggle("Global shortcut ⌃⌥S: bring AI Shelf forward and search", isOn: $hotkey)
                Toggle("Notifications (budget alerts, new versions)", isOn: $notifyOn)
            }
        }.formStyle(.grouped)
    }

    var agentsTab: some View {
        Form {
            Section("Show these agents (only installed ones can appear)") {
                ForEach(catalog(), id: \.self) { a in
                    Toggle(isOn: enabled(a)) {
                        HStack(spacing: 6) {
                            Text(a)
                            if checkedAgents[a] != true { Text("not installed").foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Section("What each agent supports") {
                Text(
                    "claude: everything (sessions, resume, preview, delete and undo, tokens and cost, Fix Path), tried on real data.\nagy: sessions, resume, preview, delete and undo. It records no token counts.\ncodex, gemini: the same as claude except Fix Path. Built from the vendors' published source, not yet tried on real sessions.\nopencode, goose, aider, amp, cursor-agent, copilot: launch and folder list only. Their history formats are unpublished, changing, or local to each project."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Custom agents — one command name per line") {
                TextEditor(text: $custom).font(.body.monospaced()).frame(height: 60)
            }
            Section("Extra flags — one line per agent, e.g. claude --dangerously-skip-permissions") {
                TextEditor(text: $flags).font(.body.monospaced()).frame(height: 80)
            }
        }.formStyle(.grouped)
    }

    var usageTab: some View {
        Form {
            Section("Token stats") {
                Toggle("Calculate token usage (reads each session file once, then cached)", isOn: $calcStats)
                Toggle("Show statistics cards at the top of the window", isOn: $showCards)
            }
            Section("Budget") {
                TextField("Monthly budget (USD)", text: $budgetText, prompt: Text("0 = off"))
                Text("You get a notification at 80% and at 100% of this estimated monthly spend.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Sync between Macs") {
                pathRow($syncFolder, "A shared folder, e.g. in iCloud Drive")
                Text("When set, the statistics ledger is merged with ai-shelf-stats.json in this folder and written back after every scan.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Statistics data") {
                HStack {
                    Button("Export…") { exportStatsPanel() }
                    Button("Import…") { importStatsPanel() }
                }
                Text(
                    stats.dataStatus.isEmpty
                        ? "The statistics ledger keeps token totals for every session ever scanned, so lifetime numbers survive Claude Code expiring old sessions. Export it to back it up or move it to another Mac; import merges (new sessions are added, the newer record wins)."
                        : stats.dataStatus
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cost estimates: official list prices (USD per million tokens)") {
                HStack {
                    Button(book.busy ? "Fetching…" : "Fetch official prices now") { book.refresh() }.disabled(book.busy)
                    Toggle("Update weekly", isOn: $autoPrices)
                }
                if !book.status.isEmpty { Text(book.status).font(.caption).foregroundStyle(.secondary) }
                Table(book.rows) {
                    TableColumn("Model") { Text($0.id) }
                    TableColumn("Source") { Text($0.src) }.width(80)
                    TableColumn("Input") { Text(String(format: "%g", $0.p[0])).monospacedDigit() }.width(55)
                    TableColumn("Output") { Text(String(format: "%g", $0.p[1])).monospacedDigit() }.width(55)
                    TableColumn("Cache write") { Text(String(format: "%g", $0.p[2])).monospacedDigit() }.width(80)
                    TableColumn("Cache read") { Text(String(format: "%g", $0.p[3])).monospacedDigit() }.width(80)
                }.frame(height: 190)
                Text(
                    "Fetched from Anthropic's, OpenAI's and Google's own pricing pages. Estimates use: Anthropic 5-minute cache-write price and Haiku's short-prompt tier; OpenAI standard short-context text models plus Codex; Google standard tier, prompts up to 200k tokens, the price in effect today. A vendor whose page can't be read keeps its previous prices."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Your own prices override the fetched ones") {
                TextEditor(text: $prices).font(.body.monospaced()).frame(height: 70)
                Text(
                    "One line per model: name (or fragment; the longest match wins), then input, output, cache-write, cache-read. Example: my-model 1 5 1.25 0.1"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    var pathsTab: some View {
        Form {
            Section("Claude history folder") { pathRow($claudePath, "~/.claude/projects") }
            Section("Antigravity history folder") { pathRow($agyPath, "~/.gemini/antigravity-cli") }
            Section("Codex sessions folder") { pathRow($codexPath, "~/.codex/sessions") }
            Section("Gemini CLI folder") { pathRow($geminiPath, "~/.gemini") }
            Text("Leave a field empty to use its default.").foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }

    func pathRow(_ text: Binding<String>, _ placeholder: String) -> some View {
        HStack {
            TextField("Folder", text: text, prompt: Text(placeholder))
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.showsHiddenFiles = true
                if panel.runModal() == .OK, let u = panel.url { text.wrappedValue = u.path }
            }
        }
    }

    func enabled(_ a: String) -> Binding<Bool> {
        Binding(
            get: { !disabledAgents().contains(a) },
            set: { on in
                var s = disabledAgents()
                if on { s.remove(a) } else { s.insert(a) }
                disabled = s.sorted().joined(separator: ",")
            })
    }
}

func exportStatsPanel() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "ai-shelf-stats-\(dayFmt.string(from: Date())).json"
    if panel.runModal() == .OK, let u = panel.url { StatsStore.shared.export(to: u) }
}

func importStatsPanel() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
    if panel.runModal() == .OK, let u = panel.url { StatsStore.shared.importStats(from: u) }
}

func showSettings() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
}
