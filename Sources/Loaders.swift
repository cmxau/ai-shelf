import SwiftUI

// MARK: - Loaders

func loadClaude() -> [Project] {
    let fm = FileManager.default
    let root = claudeRoot
    let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    return dirs.compactMap { d -> Project? in
        guard d.hasDirectoryPath else { return nil }
        let files = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "jsonl" }
        // ponytail: dir names are lossy ("_" and "/" both become "-"), so read the real cwd from a session file
        var path = "/" + d.lastPathComponent.dropFirst().replacingOccurrences(of: "-", with: "/")
        var found = false
        var rows: [(sid: String, trash: [URL], mod: Date, title: String)] = []
        for f in files {
            let head = read(f)
            if !found, let r = head.range(of: #""cwd":"([^"]*)""#, options: .regularExpression) {
                path = String(head[r].dropFirst(7).dropLast()).replacingOccurrences(of: "\\/", with: "/"); found = true
            }
            let sid = f.deletingPathExtension().lastPathComponent
            let extra = d.appendingPathComponent(sid)  // per-session folder (subagents, tool results)
            let title = head.split(separator: "\n").lazy.compactMap(msg).first { $0.role == "user" && !$0.text.hasPrefix("<") }?.text ?? "(no prompt)"
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            rows.append((sid, [f] + (fm.fileExists(atPath: extra.path) ? [extra] : []), mod, oneLine(title)))
        }
        let kids = rows.map {
            Project(
                id: d.lastPathComponent + "/" + $0.sid, path: path, trash: $0.trash, sessionID: $0.sid,
                title: $0.title, modified: $0.mod, size: diskSize($0.trash), agent: "claude")
        }.sorted { $0.modified > $1.modified }
        return Project(
            id: d.lastPathComponent, path: path, trash: [d], dir: d, sessions: kids.count,
            modified: kids.first?.modified ?? .distantPast, size: diskSize([d]), children: kids.isEmpty ? nil : kids, agent: "claude")
    }.sorted { $0.modified > $1.modified }
}

func loadAgy() -> [Project] {
    let rows =
        (try? JSONSerialization.jsonObject(
            with: sqlite(
                """
                select conversation_id id, title, preview, workspace_uris w,
                       cast(strftime('%s', last_modified_time) as integer) m from conversation_summaries
                """, json: true))) as? [[String: Any]] ?? []
    var groups: [String: [Project]] = [:]
    for r in rows {
        guard let cid = r["id"] as? String, isSafeID(cid), let w = r["w"] as? String,
            let a = try? JSONSerialization.jsonObject(with: Data(w.utf8)) as? [String],
            let path = a.first.flatMap(URL.init(string:))?.path
        else { continue }
        let t = r["title"] as? String ?? "", pv = r["preview"] as? String ?? ""
        let trash = [agyRoot.appendingPathComponent("conversations/\(cid).db"), agyRoot.appendingPathComponent("brain/\(cid)")]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let m = r["m"] as? Int ?? 0
        groups[path, default: []].append(
            Project(
                id: "agy:" + cid, path: path, trash: trash, convIDs: [cid], sessionID: cid,
                title: oneLine(t.isEmpty ? pv : t), modified: m > 0 ? Date(timeIntervalSince1970: Double(m)) : .distantPast, size: diskSize(trash), agent: "agy"
            ))
    }
    return groups.map { path, ks in
        let kids = ks.sorted { $0.modified > $1.modified }
        return Project(
            id: "agy:" + path, path: path, trash: kids.flatMap(\.trash), convIDs: kids.flatMap(\.convIDs), sessions: kids.count,
            modified: kids.first?.modified ?? .distantPast, size: kids.reduce(0) { $0 + $1.size }, children: kids, agent: "agy")
    }.sorted { $0.modified > $1.modified }
}

// Agents we can't read history for: list every known folder so any of them can be opened with that agent.
// MARK: - Codex and Gemini readers
// Built from the vendors' own source definitions (openai/codex protocol.rs, google-gemini/gemini-cli chatRecordingTypes.ts),
// NOT from real session data: neither CLI has any on this machine. Treat as unverified until tried on real sessions.

var codexRoot: URL { folder("codexRoot", home.path + "/.codex/sessions") }
var geminiRoot: URL { folder("geminiRoot", home.path + "/.gemini") }
let historyAgents = ["claude", "agy", "codex", "gemini"]  // agents we can read sessions from
let statsAgents = ["claude", "codex", "gemini"]  // of those, the ones that record token usage

func jsonObj(_ line: Substring) -> [String: Any]? { try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] }
func modDate(_ f: URL) -> Date { (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }

/// Gemini message content is a string, one part ({text}), or a list of parts.
func partsText(_ v: Any?) -> String {
    if let s = v as? String { return s }
    if let d = v as? [String: Any] { return d["text"] as? String ?? "" }
    return (v as? [Any])?.map { partsText($0) }.joined(separator: "\n") ?? ""
}

/// Folder rows built from per-file session rows.
func groupProjects(_ kids: [Project], agent: String) -> [Project] {
    Dictionary(grouping: kids, by: \.path).map { path, ks in
        let ks = ks.sorted { $0.modified > $1.modified }
        return Project(
            id: agent + ":" + path, path: path, trash: ks.flatMap(\.trash), sessions: ks.count,
            modified: ks.first?.modified ?? .distantPast, size: ks.reduce(0) { $0 + $1.size }, children: ks, agent: agent)
    }.sorted { $0.modified > $1.modified }
}

/// ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl. Line 1 is session_meta (id, cwd); the first user_message is the prompt.
func loadCodex() -> [Project] {
    guard let en = FileManager.default.enumerator(at: codexRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return [] }
    var kids: [Project] = []
    for case let f as URL in en where f.pathExtension == "jsonl" && f.lastPathComponent.hasPrefix("rollout-") {
        var path = "", sid = "", title = ""
        for o in read(f).split(separator: "\n").lazy.compactMap(jsonObj) {
            guard let p = o["payload"] as? [String: Any] else { continue }
            if o["type"] as? String == "session_meta" {
                path = p["cwd"] as? String ?? path; sid = p["id"] as? String ?? sid
            } else if title.isEmpty, o["type"] as? String == "event_msg", p["type"] as? String == "user_message", let m = p["message"] as? String,
                !m.hasPrefix("<")
            {
                title = m
            }
            if !path.isEmpty && !title.isEmpty { break }
        }
        if path.isEmpty { continue }
        if sid.isEmpty { sid = String(f.deletingPathExtension().lastPathComponent.suffix(36)) }
        kids.append(
            Project(
                id: "codex:" + f.lastPathComponent, path: path, trash: [f], sessionID: sid,
                title: oneLine(title.isEmpty ? "(no prompt)" : title), modified: modDate(f), size: diskSize([f]), agent: "codex"))
    }
    return groupProjects(kids, agent: "codex")
}

/// Records of a Gemini session file: .jsonl (a metadata header, then message records and $set/$rewindTo/$patch updates)
/// or the legacy single .json object (header fields plus a "messages" array).
func geminiRecords(_ f: URL) -> [[String: Any]] {
    if f.pathExtension == "json" {
        guard let d = readCapped(f, max: 64 << 20), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return [o] + (o["messages"] as? [[String: Any]] ?? [])
    }
    return read(f).split(separator: "\n").compactMap(jsonObj)
}

/// ~/.gemini/tmp/<project>/chats/session-*.jsonl, with the project's real folder in <project>/.project_root.
func loadGemini() -> [Project] {
    let fm = FileManager.default
    var kids: [Project] = []
    for d in (try? fm.contentsOfDirectory(at: geminiRoot.appendingPathComponent("tmp"), includingPropertiesForKeys: nil)) ?? [] {
        let cwd = ((try? String(contentsOf: d.appendingPathComponent(".project_root"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if cwd.isEmpty { continue }
        let files = ((try? fm.contentsOfDirectory(at: d.appendingPathComponent("chats"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("session-") && ["json", "jsonl"].contains($0.pathExtension) }
        for f in files {
            let recs = geminiRecords(f)
            let sid = recs.lazy.compactMap { $0["sessionId"] as? String }.first ?? f.deletingPathExtension().lastPathComponent
            let title = recs.lazy.compactMap { ($0["type"] as? String) == "user" ? partsText($0["content"]) : nil }.first { !$0.isEmpty } ?? "(no prompt)"
            kids.append(
                Project(
                    id: "gemini:" + f.lastPathComponent, path: cwd, trash: [f], sessionID: sid,
                    title: oneLine(title), modified: modDate(f), size: diskSize([f]), agent: "gemini"))
        }
    }
    return groupProjects(kids, agent: "gemini")
}

func codexPreview(_ f: URL) -> [(String, String)] {
    func msgs(_ s: String, _ kind: String, reversed: Bool) -> String? {
        let lines = s.split(separator: "\n")
        return (reversed ? Array(lines.reversed()) : Array(lines)).lazy.compactMap(jsonObj).compactMap { o -> String? in
            guard let p = o["payload"] as? [String: Any], p["type"] as? String == kind, let m = p["message"] as? String, !m.hasPrefix("<") else { return nil }
            return m
        }.first
    }
    return [
        ("First message", msgs(read(f), "user_message", reversed: false) ?? ""),
        ("Last message (assistant)", msgs(read(f, tail: true, 256 << 10), "agent_message", reversed: true) ?? ""),
    ].filter { !$0.1.isEmpty }
}

func geminiPreview(_ f: URL) -> [(String, String)] {
    let head = geminiRecords(f)
    let tail = f.pathExtension == "json" ? head : read(f, tail: true, 256 << 10).split(separator: "\n").compactMap(jsonObj)
    let first = head.lazy.compactMap { ($0["type"] as? String) == "user" ? partsText($0["content"]) : nil }.first { !$0.isEmpty }
    let last = tail.reversed().lazy.compactMap { ($0["type"] as? String) == "gemini" ? partsText($0["content"]) : nil }.first { !$0.isEmpty }
    return [("First message", first ?? ""), ("Last message (assistant)", last ?? "")].filter { !$0.1.isEmpty }
}

func loadFolders() -> [Project] {
    var byPath: [String: Project] = [:]
    for p in historyAgents.flatMap(loadHistory) {
        var f = byPath[p.path] ?? Project(id: "dir:" + p.path, path: p.path)
        f.sessions += p.sessions; f.modified = max(f.modified, p.modified)
        byPath[p.path] = f
    }
    return byPath.values.sorted { $0.modified > $1.modified }
}

/// Every installed agent's sessions, grouped by folder. A project's delete covers the claude dir plus agy conversations.
func loadAll() -> [Project] {
    var kids: [String: [Project]] = [:], extra: [String: [Project]] = [:]
    for agent in historyAgents where isActive(agent) {
        for p in loadHistory(agent) {
            kids[p.path, default: []] += p.children ?? []
            extra[p.path, default: []].append(p)
        }
    }
    return kids.map { path, ks in
        let ks = ks.sorted { $0.modified > $1.modified }
        let owners = extra[path] ?? []
        return Project(
            id: "all:" + path, path: path,
            trash: owners.filter { $0.dir != nil }.flatMap(\.trash) + ks.filter { $0.agent != "claude" }.flatMap(\.trash),
            convIDs: ks.flatMap(\.convIDs), sessions: ks.count, modified: ks.first?.modified ?? .distantPast,
            size: owners.reduce(0) { $0 + $1.size }, children: ks.isEmpty ? nil : ks, agent: ks.first?.agent ?? owners.first?.agent ?? "")
    }.sorted { $0.modified > $1.modified }
}

func loadHistory(_ agent: String) -> [Project] {
    switch agent {
    case "claude": return loadClaude()
    case "agy": return loadAgy()
    case "codex": return loadCodex()
    case "gemini": return loadGemini()
    default: return []
    }
}

func loadProjects(_ agent: String) -> [Project] {
    agent == "all" ? loadAll() : historyAgents.contains(agent) ? loadHistory(agent) : loadFolders()
}

func sessionPreview(_ p: Project) -> [(String, String)] {
    guard p.sessionID != nil else { return [] }
    let cut = { (s: String) in String(s.prefix(800)) }
    if p.agent == "codex", let f = p.trash.first { return codexPreview(f).map { ($0.0, cut($0.1)) } }
    if p.agent == "gemini", let f = p.trash.first { return geminiPreview(f).map { ($0.0, cut($0.1)) } }
    if let cid = p.convIDs.first {  // agy keeps only a title + preview outside its binary DBs
        let row =
            ((try? JSONSerialization.jsonObject(
                with: sqlite("select title, preview from conversation_summaries where conversation_id=\(sqlQuote(cid))", json: true)))
            as? [[String: Any]])?.first
        return [("Title", row?["title"] as? String ?? ""), ("Preview", row?["preview"] as? String ?? "")].filter { !$0.1.isEmpty }.map { ($0.0, cut($0.1)) }
    }
    guard let f = p.trash.first else { return [] }
    let first = read(f).split(separator: "\n").lazy.compactMap(msg).first { $0.role == "user" && !$0.text.hasPrefix("<") }
    let last = read(f, tail: true, 256 << 10).split(separator: "\n").reversed().lazy.compactMap(msg).first { !$0.text.hasPrefix("<") }
    return [("First message", first?.text ?? ""), ("Last message" + (last.map { " (\($0.role))" } ?? ""), last?.text ?? "")]
        .filter { !$0.1.isEmpty }.map { ($0.0, cut($0.1)) }
}

// Point a claude project at a new folder: rewrite "cwd" in its sessions and rename its history dir to match.
func relocate(_ p: Project, to new: String) -> String? {
    guard let dir = p.dir else {
        return
            "Fix Path works on Claude projects only. Antigravity stores workspace paths inside binary databases, where a naive rewrite could corrupt conversations."
    }
    let fm = FileManager.default
    // only a history dir that sits directly in the Claude root, and only to an absolute, plain path
    let root = claudeRoot.resolvingSymlinksInPath().path
    guard dir.deletingLastPathComponent().resolvingSymlinksInPath().path == root, new.hasPrefix("/"), !hasControl(new) else {
        return "Fix Path only works on projects inside \(claudeRoot.path), with an absolute new folder."
    }
    let name = String(new.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    let dest = dir.deletingLastPathComponent().appendingPathComponent(name)
    if dest != dir && fm.fileExists(atPath: dest.path) { return "That folder already has its own Claude history." }
    let jsonNew = new.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")  // keep the JSON valid
    for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "jsonl" {
        guard (try? f.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true, var t = try? String(contentsOf: f, encoding: .utf8) else {
            continue
        }
        let perms = (try? fm.attributesOfItem(atPath: f.path)[.posixPermissions]) as? NSNumber
        for old in [p.path, p.path.replacingOccurrences(of: "/", with: "\\/")] {
            t = t.replacingOccurrences(of: "\"cwd\":\"\(old)\"", with: "\"cwd\":\"\(jsonNew)\"")
        }
        if (try? t.write(to: f, atomically: true, encoding: .utf8)) != nil, let perms {
            try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: f.path)
        }
    }
    do { if dest != dir { try fm.moveItem(at: dir, to: dest) } } catch { return error.localizedDescription }
    return nil
}
