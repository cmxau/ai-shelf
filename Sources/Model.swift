import SwiftUI

// MARK: - Model (ObservableObject, not @State: CLT-only machines lack the SwiftUIMacros plugin)

final class Model: ObservableObject {
    static let shared = Model()
    struct Undo { var moves: [(URL, URL)]; var sql: String }
    @Published var projects: [Project] = []
    @Published var selection = Set<String>()
    @Published var pending: [Project] = []
    @Published var error: String?
    @Published var query = ""
    @Published var searchOpen = false
    @Published var preview: [(String, String)] = []
    @Published var undos: [Undo] = []
    @Published var sortOrder = [RowSort(.when, .reverse)]
    @Published var agents: [String] = []
    @Published var pins = Set(UserDefaults.standard.stringArray(forKey: Pref.pins) ?? []) {
        didSet { UserDefaults.standard.set(pins.sorted(), forKey: Pref.pins) }
    }
    @Published var notes = UserDefaults.standard.dictionary(forKey: Pref.notes) as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(notes, forKey: Pref.notes) }
    }
    @Published var running = Set<String>()  // working dirs with a live agent process
    @Published var contentHits = Set<String>()  // session ids whose conversation text matches the search
    @Published var noteKey: String?
    @Published var noteDraft = ""
    private var searchGen = 0

    init() {
        // The toolbar pickers are per-session; each launch starts from the defaults chosen in Settings.
        refreshAgents()
        let d = UserDefaults.standard
        let agent = setting(Pref.defaultAgent).nonEmpty ?? "claude"
        d.set(agent == "all" || agents.contains(agent) ? agent : agents.first ?? "all", forKey: Pref.cli)
        d.set(setting(Pref.defaultTerminal).nonEmpty ?? "Terminal", forKey: Pref.terminal)
        applyDock()
        reload()
        PriceBook.shared.refreshIfStale()
        Updater.shared.launchCheck()
        HotKey.update()
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.refreshRunning() }
    }

    // MARK: pins, notes
    func markKey(_ p: Project) -> String { p.sessionID != nil ? p.id : p.path }

    func togglePin() {
        for p in rows(selection) {
            let k = markKey(p)
            if pins.contains(k) { pins.remove(k) } else { pins.insert(k) }
        }
    }

    func editNote() {
        guard let p = rows(selection).first else { return }
        noteKey = markKey(p); noteDraft = notes[markKey(p)] ?? ""
    }

    func saveNote() {
        if let k = noteKey {
            let t = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            notes[k] = t.isEmpty ? nil : t
        }
        noteKey = nil
    }

    // MARK: search inside conversations
    /// Greps the session files for the query (case-insensitive, literal) off the main thread; rows light up as hits arrive.
    func searchContent() {
        searchGen += 1
        let gen = searchGen, q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { contentHits = []; return }
        var byPath: [String: String] = [:]
        for p in projects.flatMap({ $0.children ?? [] }) where p.sessionID != nil { if let f = p.trash.first { byPath[f.path] = p.id } }
        DispatchQueue.global(qos: .userInitiated).async {
            var hits = Set<String>()
            let paths = Array(byPath.keys)
            for i in stride(from: 0, to: paths.count, by: 300) {
                if gen != self.searchGen { return }
                for f in capture("/usr/bin/grep", ["-ilF", "--", q] + paths[i..<min(i + 300, paths.count)]).split(separator: "\n") {
                    if let id = byPath[String(f)] { hits.insert(id) }
                }
            }
            DispatchQueue.main.async { if gen == self.searchGen { self.contentHits = hits } }
        }
    }

    // MARK: running sessions
    /// `lsof` reports real paths, but a project may be stored under a symlinked one (/tmp, /var…), so compare both.
    func isRunning(_ p: Project) -> Bool { !running.isEmpty && (running.contains(p.path) || running.contains(realPath(p.path))) }

    func refreshRunning() {
        DispatchQueue.global(qos: .utility).async {
            let names = Set(catalog())
            let launchers: Set<String> = ["node", "python", "python3", "bun", "deno"]
            func base(_ s: Substring) -> String { URL(fileURLWithPath: String(s)).lastPathComponent }
            var pids: [String] = []
            for line in capture("/bin/ps", ["-axo", "pid=,command="]).split(separator: "\n") {
                let w = line.split(separator: " ")
                guard w.count >= 2 else { continue }
                let first = base(w[1])
                if names.contains(first) || (launchers.contains(first) && w.count > 2 && names.contains(base(w[2]))) { pids.append(String(w[0])) }
            }
            var dirs = Set<String>()
            if !pids.isEmpty {
                for l in capture("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-p", pids.joined(separator: ",")]).split(separator: "\n") where l.hasPrefix("n")
                {
                    dirs.insert(String(l.dropFirst()))
                }
            }
            DispatchQueue.main.async { if self.running != dirs { self.running = dirs } }
        }
    }

    // MARK: clean up
    func cleanUp(olderThan days: Int?) {
        let cutoff = Date().addingTimeInterval(-Double(days ?? 0) * 86_400)
        let hits = projects.flatMap { $0.children ?? [] }.filter {
            $0.sessionID != nil && !pins.contains(markKey($0)) && (days == nil ? ($0.title == "(no prompt)" || $0.title.isEmpty) : $0.modified < cutoff)
        }
        if hits.isEmpty { error = days == nil ? "No empty sessions found." : "No sessions older than \(days!) days." } else { request(hits) }
    }

    func exportSelected() { if let p = rows(selection).first { exportTranscript(p) } }

    /// Sort menu: same field flips direction; a new field starts A→Z for text, largest/newest first for numbers and dates.
    func sortBy(_ f: RowSort.Field) {
        if let c = sortOrder.first, c.field == f {
            sortOrder = [RowSort(f, c.order == .forward ? .reverse : .forward)]
        } else {
            sortOrder = [RowSort(f, f.isText ? .forward : .reverse)]
        }
    }

    func refreshAgents() { agents = activeAgents() }

    func reload() {
        projects = loadProjects(UserDefaults.standard.string(forKey: Pref.cli) ?? "claude")
        selection = []; preview = []
        StatsStore.shared.refresh(projects)
        refreshRunning()
    }

    func rows(_ ids: Set<String>) -> [Project] { (projects + projects.flatMap { $0.children ?? [] }).filter { ids.contains($0.id) } }

    func updatePreview() { preview = selection.count == 1 ? rows(selection).first.map(sessionPreview) ?? [] : [] }

    /// Ask for delete confirmation. A selected project already covers its selected sessions.
    func ask(_ ids: Set<String>) {
        let ps = rows(ids)
        request(ps.filter { p in !ps.contains { $0.children?.contains { $0.id == p.id } == true } })
    }

    /// Confirm first (unless Settings says not to), then delete.
    func request(_ ps: [Project]) {
        let ps = ps.filter { !$0.trash.isEmpty }
        if ps.isEmpty { return }
        if pref(Pref.confirmDelete, true) { pending = ps } else { delete(ps) }
    }

    func delete(_ ps: [Project]) {
        pending = []
        let toTrash = pref(Pref.trashDelete, true)  // off = permanent, so nothing to undo
        var moves: [(URL, URL)] = []
        var refused: [String] = []
        for u in ps.flatMap(\.trash) {
            guard insideHistoryRoots(u) else { refused.append(u.path); continue }
            if toTrash {
                var out: NSURL?
                if (try? FileManager.default.trashItem(at: u, resultingItemURL: &out)) != nil, let o = out { moves.append((u, o as URL)) }
            } else {
                try? FileManager.default.removeItem(at: u)
            }
        }
        var sql = ""
        let ids = ps.flatMap(\.convIDs).filter(isSafeID)
        if !ids.isEmpty {
            let list = "(" + ids.map(sqlQuote).joined(separator: ",") + ")"
            // keep the rows as INSERT statements so Undo can put them back
            if toTrash {
                sql = String(
                    decoding: sqlite(".mode insert conversation_summaries", "select * from conversation_summaries where conversation_id in \(list)"),
                    as: UTF8.self)
            }
            _ = sqlite("delete from conversation_summaries where conversation_id in \(list)")
        }
        if toTrash { undos.append(Undo(moves: moves, sql: sql)) }
        reload()
        if !refused.isEmpty { error = "Left alone (outside the configured history folders): " + refused.prefix(3).joined(separator: ", ") }
    }

    func openSelected() { rows(selection).filter(\.exists).forEach(openProject) }

    func revealSelected() {
        NSWorkspace.shared.activateFileViewerSelecting(rows(selection).filter(\.exists).map { URL(fileURLWithPath: $0.path) })
    }

    func copySelected() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rows(selection).map(\.path).joined(separator: "\n"), forType: .string)
    }

    func fixSelected() {
        guard let p = rows(selection).first else { return }
        if p.dir == nil { error = relocate(p, to: ""); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "New location for \(p.path)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = relocate(p, to: url.path)
        reload()
    }

    func undo() {
        guard let u = undos.popLast() else { return }
        for (from, to) in u.moves { try? FileManager.default.moveItem(at: to, to: from) }
        if u.sql.hasPrefix("INSERT INTO conversation_summaries") { _ = sqlite(u.sql) }  // only ever our own replayed rows
        reload()
    }
}

func applyDock() {
    NSApp?.setActivationPolicy(pref(Pref.showDock, true) ? .regular : .accessory)
}
