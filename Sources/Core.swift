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

extension String { var nonEmpty: String? { isEmpty ? nil : self } }
func setting(_ k: String) -> String { UserDefaults.standard.string(forKey: k) ?? "" }
func pref(_ k: String, _ fallback: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? fallback }

func folder(_ key: String, _ fallback: String) -> URL {
    let s = setting(key).trimmingCharacters(in: .whitespaces)
    return URL(fileURLWithPath: ((s.isEmpty ? fallback : s) as NSString).expandingTildeInPath)
}
var claudeRoot: URL { folder("claudeRoot", home.path + "/.claude/projects") }
var agyRoot: URL { folder("agyRoot", home.path + "/.gemini/antigravity-cli") }

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
    p.arguments = (json ? ["-json"] : []) + [agyRoot.appendingPathComponent("conversation_summaries.db").path] + sql
    p.standardOutput = out
    try? p.run()
    let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return d
}
