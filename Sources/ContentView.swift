import SwiftUI

// MARK: - UI

struct ContentView: View {
    @ObservedObject var m = Model.shared
    @AppStorage(Pref.cli) var cli = "claude"
    @AppStorage(Pref.terminal) var terminal = "Terminal"
    @AppStorage(Pref.autoReload) var autoReload = false
    @AppStorage(Pref.trashDelete) var trashDelete = true
    @AppStorage(Pref.showCards) var showCards = true
    @AppStorage(Pref.columns) var cols = TableColumnCustomization<Project>()  // visibility + order, edited from the column headers
    @AppStorage(Pref.prices) var prices = ""  // only here so cost cells refresh when prices change
    @ObservedObject var stats = StatsStore.shared
    @ObservedObject var book = PriceBook.shared
    @Environment(\.openWindow) var openWindow
    @FocusState var focused: Bool

    var hasHistory: Bool { cli == "all" || resumeFlag[cli] != nil }

    var visible: [Project] {
        let q = m.query.lowercased()
        func hit(_ p: Project) -> Bool { p.path.lowercased().contains(q) || p.title.lowercased().contains(q) || m.contentHits.contains(p.id) }
        let base = q.isEmpty ? m.projects : m.projects.filter { hit($0) || ($0.children ?? []).contains(where: hit) }
        let sorted = base.sorted(using: m.sortOrder).map {
            var p = $0; p.children = p.children?.sorted(using: m.sortOrder); return p
        }
        return sorted.filter { m.pins.contains($0.path) } + sorted.filter { !m.pins.contains($0.path) }  // pinned projects stay on top
    }

    var body: some View {
        let data = visible  // sorted once per render, not once per cell
        let number = Dictionary(uniqueKeysWithValues: data.enumerated().map { ($1.id, String($0 + 1)) })
        VStack(spacing: 0) {
            if showCards { StatsCards().padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 10) }
            Table(data, children: \.children, selection: $m.selection, sortOrder: $m.sortOrder, columnCustomization: $cols) {
                TableColumn("Project / Session", sortUsing: RowSort(.name)) { nameCell($0) }.customizationID("name").disabledCustomizationBehavior(.visibility)
                TableColumn("#") { Text(number[$0.id] ?? "") }.width(36).customizationID("num")
                TableColumn("Agent", sortUsing: RowSort(.agent)) { Text($0.agentLabel) }.width(100).customizationID("agent")
                TableColumn("Sessions", sortUsing: RowSort(.sessions)) { Text($0.sessionID == nil ? "\($0.sessions)" : "") }.width(60).customizationID(
                    "sessions")
                TableColumn("Tokens", sortUsing: RowSort(.tokens)) { Text(tokens($0)).monospacedDigit() }.width(65).customizationID("tokens")
                TableColumn("Model", sortUsing: RowSort(.model)) { Text(modelName($0)).lineLimit(1) }.width(130).customizationID("model").defaultVisibility(
                    .hidden)
                TableColumn("Est. cost", sortUsing: RowSort(.cost)) { Text(costText($0)).monospacedDigit() }.width(70).customizationID("cost")
                Group {
                    TableColumn("Size", sortUsing: RowSort(.size)) {
                        Text($0.size == 0 ? "" : ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file))
                    }.width(70).customizationID("size")
                    TableColumn("Last used", sortUsing: RowSort(.when)) { Text(when($0)) }.width(110).customizationID("when")
                    TableColumn("Note") { noteCell($0) }.width(140).customizationID("note")
                    TableColumn("Status") { flag($0) }.width(70).customizationID("status").disabledCustomizationBehavior(.all)
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if !ids.isEmpty {
                    Button("Open in Terminal") { open(ids) }
                    Button("Show in Finder") { reveal(ids) }
                    Button("Copy Path") { copy(ids) }
                    Button("Fix Path…") { fix(ids) }
                    Divider()
                    Button(pinLabel(ids)) {
                        m.selection = ids; m.togglePin()
                    }
                    Button("Edit Note…") {
                        m.selection = ids; m.editNote()
                    }
                    Button("Export as Markdown…") {
                        m.selection = ids; m.exportSelected()
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { m.ask(ids) }
                }
            } primaryAction: {
                open($0)
            }

            if !details.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(details, id: \.0) { detailRow($0) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.frame(height: 190)
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("Agent", selection: $cli) {
                    Text("All agents").tag("all"); ForEach(m.agents, id: \.self) { Text($0).tag($0) }
                }
                .padding(.horizontal, 10)
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Picker("Terminal", selection: $terminal) { ForEach(terminals, id: \.self) { Text($0).tag($0) } }
                    .padding(.horizontal, 10)
            }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                Button {
                    open(m.selection)
                } label: {
                    Label("Open in Terminal", systemImage: "terminal")
                }
                .help("Open in Terminal").disabled(m.selection.isEmpty)
                Button {
                    fix(m.selection)
                } label: {
                    Label("Fix Path", systemImage: "folder.badge.gearshape")
                }
                .help("Fix Path…").disabled(m.selection.isEmpty || cli != "claude")
            }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                Button {
                    m.ask(m.selection)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help(trashDelete ? "Move to Trash" : "Delete permanently").disabled(m.selection.isEmpty || !hasHistory)
                Button {
                    m.request(m.projects.filter { !$0.exists })
                } label: {
                    Label("Delete Missing", systemImage: "questionmark.folder")
                }
                .help("Delete all projects whose folder is missing").disabled(!hasHistory || m.projects.allSatisfy(\.exists))
                Button {
                    m.undo()
                } label: {
                    Label("Undo Delete", systemImage: "arrow.uturn.backward")
                }
                .help("Undo last delete").disabled(m.undos.isEmpty)
            }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                Button {
                    m.reload()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }.help("Reload")
                Menu {
                    SortButtons()
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }.help("Sort by…")
                Button {
                    openWindow(id: "stats")
                } label: {
                    Label("Usage Stats", systemImage: "chart.bar")
                }.help("Usage stats")
            }
            ToolbarSpacer(.flexible)
            ToolbarItem {
                if m.searchOpen {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search", text: $m.query).textFieldStyle(.plain).focused($focused)
                            .onExitCommand { closeSearch(force: true) }
                            .onChange(of: focused) { if !focused { closeSearch(force: false) } }
                            .onAppear { focused = true }
                    }
                    .padding(.horizontal, 10).frame(width: 200, height: 28)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 3).opacity(focused ? 1 : 0))
                } else {
                    Button {
                        m.searchOpen = true
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .help("Search").keyboardShortcut("f", modifiers: .command)
                }
            }
            .sharedBackgroundVisibility(m.searchOpen ? .hidden : .automatic)
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)  // an open window always gets a menu bar, even with "Show Dock icon" off
            NSApp.activate(ignoringOtherApps: true)
            if UserDefaults.standard.integer(forKey: Pref.columnsVersion) < 3 {
                cols = TableColumnCustomization(); UserDefaults.standard.set(3, forKey: Pref.columnsVersion)
            }
            // a saved choice may no longer be installed
            if cli != "all" && !m.agents.contains(cli) { cli = m.agents.first ?? "all" }
            if !terminals.contains(terminal) { terminal = "Terminal" }
        }
        .onChange(of: cli) { m.reload() }
        .onChange(of: m.query) { m.searchContent() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            DispatchQueue.main.async { applyDock() }  // back to menu-bar-only if the Dock icon is turned off
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if autoReload { m.reload() } }
        .onChange(of: m.selection) { m.updatePreview() }
        .alert("Note", isPresented: Binding(get: { m.noteKey != nil }, set: { if !$0 { m.noteKey = nil } })) {
            TextField("Note", text: $m.noteDraft)
            Button("Save") { m.saveNote() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("AI Shelf", isPresented: Binding(get: { m.error != nil }, set: { _ in m.error = nil })) {
        } message: {
            Text(m.error ?? "")
        }
        .confirmationDialog(
            trashDelete ? "Move \(m.pending.count) item(s) to Trash?" : "Permanently delete \(m.pending.count) item(s)?",
            isPresented: Binding(get: { !m.pending.isEmpty }, set: { if !$0 { m.pending = [] } }),
            presenting: m.pending.isEmpty ? nil : m.pending
        ) { ps in
            Button(trashDelete ? "Move to Trash" : "Delete Permanently", role: .destructive) { m.delete(ps) }
        } message: { _ in
            Text("Only saved conversations are removed, never your code." + (trashDelete ? " Undo is in the toolbar." : " This can't be undone."))
        }
    }

    /// Collapse back to the magnifier like Finder: Esc always, click-away only when the field is empty.
    func closeSearch(force: Bool) {
        if force { m.query = "" }
        if force || m.query.isEmpty { m.searchOpen = false }
    }

    /// Last message time from the session itself when known; file mtime otherwise.
    func when(_ p: Project) -> String {
        let d = stats.summary(p)?.last.map { Date(timeIntervalSince1970: $0) } ?? p.modified
        return d == .distantPast ? "—" : d.formatted(.relative(presentation: .named))
    }

    func tokens(_ p: Project) -> String {
        if let s = stats.summary(p) { return compact(s.total.fresh) }
        return p.agent == "claude" && stats.computing ? "…" : ""
    }

    func modelName(_ p: Project) -> String { stats.summary(p)?.models.max { $0.value.output < $1.value.output }?.key ?? "" }

    func costText(_ p: Project) -> String { stats.summary(p).map { money(cost($0.models)) } ?? "" }

    /// Usage details for the single selected row (session or whole project).
    var details: [(String, String)] { m.preview + usageLines }

    func detailRow(_ l: (String, String)) -> some View {
        VStack(alignment: .leading) {
            Text(l.0).font(.caption).foregroundStyle(.secondary)
            Text(l.1).textSelection(.enabled)
        }
    }

    var usageLines: [(String, String)] {
        guard m.selection.count == 1, let p = m.rows(m.selection).first, let s = stats.summary(p) else { return [] }
        let u = s.total
        var out = [
            (
                "Tokens",
                "\(u.fresh.formatted()) new = \(u.input.formatted()) input + \(u.output.formatted()) output + \(u.cacheWrite.formatted()) cache writes\n"
                    + "\(u.cacheRead.formatted()) cache reads (re-used context, not counted in the Tokens column)"
            )
        ]
        if !s.models.isEmpty { out.append(("Model", s.models.sorted { $0.value.output > $1.value.output }.map(\.key).joined(separator: ", "))) }
        if let a = s.first, let b = s.last {
            out.append(
                (
                    "Active",
                    "\(stamp(a)) → \(stamp(b))  ("
                        + Duration.seconds(b - a).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
                        + ")"
                ))
        }
        let c = money(cost(s.models))
        if !c.isEmpty { out.append(("Est. cost (estimate)", c)) }
        return out
    }

    @ViewBuilder func nameCell(_ p: Project) -> some View {
        HStack(spacing: 4) {
            if m.pins.contains(m.markKey(p)) { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
            if p.sessionID != nil {
                Text(p.title).lineLimit(1)
            } else {
                VStack(alignment: .leading) {
                    Text(p.name).bold()
                    Text(p.path).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    func noteCell(_ p: Project) -> some View { Text(m.notes[m.markKey(p)] ?? "").lineLimit(1).foregroundStyle(.secondary) }

    func pinLabel(_ ids: Set<String>) -> String {
        let all = m.rows(ids).allSatisfy { m.pins.contains(m.markKey($0)) }
        return all ? "Unpin" : "Pin to Top"
    }

    @ViewBuilder func flag(_ p: Project) -> some View {
        if p.sessionID == nil && !p.exists {
            Text("missing").foregroundStyle(.orange)
        } else if p.sessionID == nil && m.isRunning(p) {
            Label("running", systemImage: "circle.fill").labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.green)
        }
    }

    /// Context-menu actions act on the clicked rows, so they become the selection first.
    func open(_ ids: Set<String>) { m.selection = ids; m.openSelected() }
    func reveal(_ ids: Set<String>) { m.selection = ids; m.revealSelected() }
    func copy(_ ids: Set<String>) { m.selection = ids; m.copySelected() }
    func fix(_ ids: Set<String>) { m.selection = ids; m.fixSelected() }
}

/// The Sort menu's items (shared by the menu bar and the toolbar): the active field shows a check and its direction.
struct SortButtons: View {
    @ObservedObject var m = Model.shared
    var body: some View {
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
}
