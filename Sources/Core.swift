import SwiftUI

// MARK: - Data

struct Project: Identifiable {
    let id: String
    let path: String  // working dir the sessions belong to
    var trash: [URL] = []  // what "delete" moves to the Trash
    var dir: URL? = nil  // claude only: ~/.claude/projects/<dir> (needed by Fix Path)
    var convIDs: [String] = []  // agy only: conversation ids (rows in conversation_summaries)
    var sessionID: String? = nil  // non-nil on session (child) rows
    var title = ""
    var sessions = 0
    var modified = Date.distantPast
    var size: Int64 = 0
    var children: [Project]? = nil
    var agent = ""  // which CLI owns this row ("" = unknown, use the picker)
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    /// "claude · agy" on a folder row that has sessions from several agents; the row's own agent otherwise.
    var agentLabel: String {
        if sessionID != nil || children == nil { return agent }
        var seen: [String] = []
        for a in (children ?? []).map(\.agent) where !seen.contains(a) { seen.append(a) }
        return seen.joined(separator: " · ")
    }
}

/// One comparator for every sortable column, so a single sort order can drive the whole table (header clicks and the Sort menu).
struct RowSort: SortComparator {
    enum Field: String, CaseIterable {
        case name, agent, sessions, tokens, model, cost, size, when
        var title: String {
            switch self {
            case .name: return "Name";
            case .agent: return "Agent";
            case .sessions: return "Sessions";
            case .tokens: return "Tokens"
            case .model: return "Model";
            case .cost: return "Est. cost";
            case .size: return "Size";
            case .when: return "Last used"
            }
        }
        var isText: Bool { self == .name || self == .agent || self == .model }
    }
    var field: Field
    var order: SortOrder = .forward
    init(_ field: Field, _ order: SortOrder = .forward) { self.field = field; self.order = order }

    func compare(_ a: Project, _ b: Project) -> ComparisonResult {
        let r: ComparisonResult
        if field.isText {
            r = text(a).localizedCaseInsensitiveCompare(text(b))
        } else {
            let x = number(a), y = number(b); r = x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
        }
        guard order == .reverse else { return r }
        return r == .orderedAscending ? .orderedDescending : r == .orderedDescending ? .orderedAscending : .orderedSame
    }
    private func text(_ p: Project) -> String {
        switch field {
        case .name: return p.sessionID == nil ? p.name : p.title
        case .agent: return p.agentLabel
        default: return StatsStore.shared.summary(p)?.models.max { $0.value.output < $1.value.output }?.key ?? ""
        }
    }
    private func number(_ p: Project) -> Double {
        let s = StatsStore.shared.summary(p)
        switch field {
        case .sessions: return Double(p.sessions)
        case .tokens: return Double(s?.total.fresh ?? -1)
        case .cost: return s.flatMap { cost($0.models)?.usd } ?? -1
        case .size: return Double(p.size)
        default: return s?.last ?? (p.modified == .distantPast ? 0 : p.modified.timeIntervalSince1970)
        }
    }
}

let home = FileManager.default.homeDirectoryForCurrentUser

let repoSlug = "cmxau/ai-shelf"

/// ~/Library/Caches/ai-shelf. The statistics ledger lives here, so a folder left by the app's old name (SessionShelf) is moved over once.
let cacheDir: URL = {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let new = base.appendingPathComponent("ai-shelf"), old = base.appendingPathComponent("SessionShelf")
    if !FileManager.default.fileExists(atPath: new.path), FileManager.default.fileExists(atPath: old.path) {
        try? FileManager.default.moveItem(at: old, to: new)
    }
    return new
}()

// MARK: - Settings (all plain UserDefaults keys; the Settings window edits them through @AppStorage)

/// Every UserDefaults key in one place (the Settings window edits them through @AppStorage), so a typo can't silently make a new setting.
enum Pref {
    static let cli = "cli"
    static let terminal = "terminal"
    static let defaultAgent = "defaultAgent"
    static let defaultTerminal = "defaultTerminal"
    static let openInTab = "openInTab"
    static let confirmDelete = "confirmDelete"
    static let trashDelete = "trashDelete"
    static let autoReload = "autoReload"
    static let columns = "columns"
    static let menuCount = "menuCount"
    static let showDock = "showDock"
    static let disabledAgents = "disabledAgents"
    static let customAgents = "customAgents"
    static let agentFlags = "agentFlags"
    static let claudeRoot = "claudeRoot"
    static let agyRoot = "agyRoot"
    static let codexRoot = "codexRoot"
    static let geminiRoot = "geminiRoot"
    static let calcStats = "calcStats"
    static let showCards = "showCards"
    static let prices = "prices"
    static let autoPrices = "autoPrices"
    static let hotkey = "hotkey"
    static let notify = "notify"
    static let monthlyBudget = "monthlyBudget"
    static let syncFolder = "syncFolder"
    static let statsGroup = "statsGroup"
    static let autoCheckUpdates = "autoCheckUpdates"
    static let autoInstallUpdates = "autoInstallUpdates"
    static let lastUpdateCheck = "lastUpdateCheck"
    static let pins = "pins"
    static let notes = "notes"
    static let columnsVersion = "columnsVersion"
}

extension String { var nonEmpty: String? { isEmpty ? nil : self } }
func setting(_ k: String) -> String { UserDefaults.standard.string(forKey: k) ?? "" }
func pref(_ k: String, _ fallback: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? fallback }

func folder(_ key: String, _ fallback: String) -> URL {
    let s = setting(key).trimmingCharacters(in: .whitespaces)
    return URL(fileURLWithPath: ((s.isEmpty ? fallback : s) as NSString).expandingTildeInPath)
}
var claudeRoot: URL { folder(Pref.claudeRoot, home.path + "/.claude/projects") }
var agyRoot: URL { folder(Pref.agyRoot, home.path + "/.gemini/antigravity-cli") }

func diskSize(_ urls: [URL]) -> Int64 {
    let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
    func one(_ u: URL) -> Int64 { Int64((try? u.resourceValues(forKeys: keys).totalFileAllocatedSize) ?? 0) }
    var total: Int64 = 0
    for u in urls {
        total += one(u)
        for case let f as URL in FileManager.default.enumerator(at: u, includingPropertiesForKeys: Array(keys)) ?? NSEnumerator() { total += one(f) }
    }
    return total
}

/// Whole-file read with a size cap (nil = missing or bigger than `max`), so a huge or hostile file can't exhaust memory.
func readCapped(_ f: URL, max: Int) -> Data? {
    guard let h = try? FileHandle(forReadingFrom: f) else { return nil }
    defer { try? h.close() }
    guard let d = try? h.read(upToCount: max + 1), d.count <= max else { return nil }
    return d
}

/// Cache files hold project paths, so the folder is 0700 and files 0600.
func privateWrite(_ d: Data, to u: URL) {
    let fm = FileManager.default
    try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheDir.path)
    if (try? d.write(to: u, options: .atomic)) != nil { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path) }
}

/// Ids that name files (conversation ids, session ids) must be plain tokens: no separators, quotes or spaces.
func isSafeID(_ s: String) -> Bool {
    !s.isEmpty && s.utf8.count <= 128
        && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 || $0 == 46 }
        && !s.hasPrefix(".")
}

/// SQL string literal: quotes doubled, NULs dropped.
func sqlQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "\u{0}", with: "").replacingOccurrences(of: "'", with: "''") + "'" }

/// Deleting is only allowed for items directly or deeper inside a configured history folder (symlinks resolved on the parent, so a
/// link can't point the delete elsewhere; the item itself is trashed/removed as a link, never followed).
func insideHistoryRoots(_ u: URL) -> Bool {
    let parent = u.deletingLastPathComponent().resolvingSymlinksInPath().path
    return [claudeRoot, agyRoot, codexRoot, geminiRoot].contains { r in
        let root = r.resolvingSymlinksInPath().path
        return root != "/" && root != home.resolvingSymlinksInPath().path && (parent == root || parent.hasPrefix(root + "/"))
    }
}

func read(_ f: URL, tail: Bool = false, _ n: Int = 512 << 10) -> String {
    guard let h = try? FileHandle(forReadingFrom: f) else { return "" }
    defer { try? h.close() }
    if tail, let end = try? h.seekToEnd(), end > UInt64(n) { try? h.seek(toOffset: end - UInt64(n)) } else { try? h.seek(toOffset: 0) }
    return String(decoding: (try? h.read(upToCount: n)) ?? Data(), as: UTF8.self)
}

/// One jsonl line -> (role, text), or nil for non-chat lines, tool results, and meta noise.
func msg(_ line: Substring) -> (role: String, text: String)? {
    guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
        let role = o["type"] as? String, role == "user" || role == "assistant",
        o["isMeta"] as? Bool != true, let m = o["message"] as? [String: Any]
    else { return nil }
    var t = ""
    if let s = m["content"] as? String {
        t = s
    } else if let a = m["content"] as? [[String: Any]] {
        t = a.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }
    t = t.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : (role, t)
}

func oneLine(_ s: String) -> String { String((s.split(separator: "\n").first ?? "").prefix(120)) }

func sqlite(_ sql: String..., json: Bool = false) -> Data {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    p.arguments = ["-safe"] + (json ? ["-json"] : []) + [agyRoot.appendingPathComponent("conversation_summaries.db").path] + sql
    p.standardOutput = out
    try? p.run()
    let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return d
}
