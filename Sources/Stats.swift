import SwiftUI

// MARK: - Usage stats (Claude only: its session files record token usage per message)

struct Usage: Codable {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    /// Headline number: tokens processed fresh. Cache reads are re-used context and would dwarf everything, so they're shown separately.
    var fresh: Int { input + output + cacheWrite }
    static func += (a: inout Usage, b: Usage) { a.input += b.input; a.output += b.output; a.cacheWrite += b.cacheWrite; a.cacheRead += b.cacheRead }
    static func + (a: Usage, b: Usage) -> Usage { var c = a; c += b; return c }
}

struct FileStats: Codable {
    var size = 0, mtime = 0.0
    var first: Double? = nil, last: Double? = nil
    var days: [String: [String: Usage]] = [:]  // local day -> model -> usage
    var models: [String: Usage] = [:]
    var total = Usage()
    var project: String? = nil  // working dir the session belonged to (kept after the session file is gone)
    var agent: String? = nil  // nil = claude (entries written before other agents were supported)

    mutating func add(_ o: FileStats) {
        first = [first, o.first].compactMap { $0 }.min(); last = [last, o.last].compactMap { $0 }.max()
        for (d, ms) in o.days { for (m, u) in ms { days[d, default: [:]][m, default: Usage()] += u } }
        for (m, u) in o.models { models[m, default: Usage()] += u }
        total += o.total
    }
    var summary: Summary { Summary(total: total, models: models, first: first, last: last) }
}

/// Everything ever recorded in the ledger, including sessions whose files Claude Code has since expired or you deleted.
struct Lifetime {
    var all = FileStats()
    var sessions = 0, projects = 0
    init() {}
    init(_ ledger: [String: FileStats]) {
        var projs = Set<String>()
        for (k, f) in ledger {
            all.add(f)
            if !k.hasPrefix("agent-") { sessions += 1; if let p = f.project { projs.insert(p) } }  // subagent logs belong to a session
        }
        projects = projs.count
    }
    var today: [String: Usage] { all.days[dayFmt.string(from: Date())] ?? [:] }
}

extension Usage {
    /// Every counter must be a believable token count: negative or huge values from a doctored file would trap on `+=` overflow.
    var plausible: Bool { [input, output, cacheWrite, cacheRead].allSatisfy { (0...(1 << 36)).contains($0) } }
}

extension FileStats {
    /// Imported/synced entries are untrusted: bounded sizes, sane counters, short strings. nil = reject the entry.
    var checked: FileStats? {
        guard days.count <= 20_000, models.count <= 1_000, total.plausible, models.values.allSatisfy(\.plausible),
            days.values.allSatisfy({ $0.count <= 1_000 && $0.keys.allSatisfy { $0.count <= 200 } && $0.values.allSatisfy(\.plausible) }),
            days.keys.allSatisfy({ $0.count <= 10 }), models.keys.allSatisfy({ $0.count <= 200 }),
            (project?.count ?? 0) <= 4096, (agent?.count ?? 0) <= 32, size >= 0, mtime.isFinite
        else { return nil }
        return self
    }
}

let maxImportBytes = 128 << 20, maxImportEntries = 500_000

struct StatsExport: Codable { var app = "ai-shelf"; var version = 1; var exported: Double; var ledger: [String: FileStats] }

/// Light aggregate used by list rows (no per-day detail).
struct Summary {
    var total = Usage(), models: [String: Usage] = [:], first: Double? = nil, last: Double? = nil
    mutating func add(_ o: Summary) {
        total += o.total
        for (m, u) in o.models { models[m, default: Usage()] += u }
        first = [first, o.first].compactMap { $0 }.min(); last = [last, o.last].compactMap { $0 }.max()
    }
}

let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
}()
let isoPlain = ISO8601DateFormatter()
let dayFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
}()
func epoch(_ s: String) -> Double? { (isoFrac.date(from: s) ?? isoPlain.date(from: s))?.timeIntervalSince1970 }

func tsOf(_ line: Data) -> Double? {
    guard let r = line.range(of: Data("\"timestamp\":\"".utf8)) else { return nil }
    let s = String(decoding: line[r.upperBound..<min(r.upperBound + 30, line.endIndex)], as: UTF8.self)
    return epoch(String(s.prefix { $0 != "\"" }))
}

/// Exact per-file totals. Claude logs one line per content block with the same message id and usage,
/// so lines are de-duplicated by message id (keeping the largest output count) or totals would be inflated.
func scan(_ url: URL, size: Int, mtime: Double) -> FileStats {
    var fs = FileStats(size: size, mtime: mtime)
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return fs }
    let lines = data.split(separator: 10)
    let nUsage = Data("\"usage\"".utf8), nAsst = Data("\"type\":\"assistant\"".utf8)
    fs.first = lines.lazy.compactMap(tsOf).first
    fs.last = lines.reversed().lazy.compactMap(tsOf).first
    var best: [String: (model: String, u: Usage, ts: Double)] = [:]
    for line in lines where line.range(of: nUsage) != nil && line.range(of: nAsst) != nil {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any],
            let model = m["model"] as? String, model != "<synthetic>"
        else { continue }
        let usage = Usage(
            input: u["input_tokens"] as? Int ?? 0, output: u["output_tokens"] as? Int ?? 0,
            cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0, cacheRead: u["cache_read_input_tokens"] as? Int ?? 0)
        let id = m["id"] as? String ?? o["uuid"] as? String ?? UUID().uuidString
        if let e = best[id], e.u.output >= usage.output { continue }
        best[id] = (model, usage, (o["timestamp"] as? String).flatMap(epoch) ?? fs.first ?? 0)
    }
    for (_, e) in best {
        fs.days[dayFmt.string(from: Date(timeIntervalSince1970: e.ts)), default: [:]][e.model, default: Usage()] += e.u
        fs.models[e.model, default: Usage()] += e.u
        fs.total += e.u
    }
    return fs
}

func fold(_ fs: inout FileStats, _ items: [(model: String, u: Usage, ts: Double)]) {
    for e in items {
        fs.days[dayFmt.string(from: Date(timeIntervalSince1970: e.ts)), default: [:]][e.model, default: Usage()] += e.u
        fs.models[e.model, default: Usage()] += e.u
        fs.total += e.u
    }
}

/// Codex: token_count events carry the session's cumulative total_token_usage, so each event's delta from the previous one is
/// attributed to that event's day and the model from the latest turn_context. OpenAI counts cached tokens inside input_tokens,
/// so fresh input = input - cached - cache writes. (Reasoning tokens are already part of output_tokens.)
func scanCodex(_ url: URL, size: Int, mtime: Double) -> FileStats {
    var fs = FileStats(size: size, mtime: mtime)
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return fs }
    let lines = data.split(separator: 10)
    fs.first = lines.lazy.compactMap(tsOf).first; fs.last = lines.reversed().lazy.compactMap(tsOf).first
    let nTok = Data("\"token_count\"".utf8), nCtx = Data("\"turn_context\"".utf8)
    var model = "unknown", prev = (i: 0, c: 0, w: 0, o: 0)
    var items: [(model: String, u: Usage, ts: Double)] = []
    for line in lines {
        let isTok = line.range(of: nTok) != nil, isCtx = line.range(of: nCtx) != nil
        guard isTok || isCtx, let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let p = o["payload"] as? [String: Any] else { continue }
        if o["type"] as? String == "turn_context" { model = p["model"] as? String ?? model; continue }
        guard o["type"] as? String == "event_msg", p["type"] as? String == "token_count",
            let t = (p["info"] as? [String: Any])?["total_token_usage"] as? [String: Any]
        else { continue }
        let cur = (
            i: t["input_tokens"] as? Int ?? 0, c: t["cached_input_tokens"] as? Int ?? 0, w: t["cache_write_input_tokens"] as? Int ?? 0,
            o: t["output_tokens"] as? Int ?? 0
        )
        // a drop = counter restarted
        let d = cur.i >= prev.i && cur.o >= prev.o ? (i: cur.i - prev.i, c: cur.c - prev.c, w: cur.w - prev.w, o: cur.o - prev.o) : cur
        prev = cur
        if d.i == 0 && d.o == 0 { continue }
        items.append(
            (
                model, Usage(input: max(0, d.i - d.c - d.w), output: d.o, cacheWrite: d.w, cacheRead: d.c),
                (o["timestamp"] as? String).flatMap(epoch) ?? fs.first ?? 0
            ))
    }
    fold(&fs, items)
    return fs
}

/// Gemini: each "gemini" message may carry tokens {input (incl. cached), output, cached, thoughts, tool}. Messages repeat as they are
/// updated, so the last record per id wins. Rewound messages stay counted: they were still billed.
func scanGemini(_ url: URL, size: Int, mtime: Double) -> FileStats {
    var fs = FileStats(size: size, mtime: mtime)
    var recs: [[String: Any]]
    if url.pathExtension == "json" {
        recs = geminiRecords(url)
        fs.first = (recs.first?["startTime"] as? String).flatMap(epoch); fs.last = (recs.first?["lastUpdated"] as? String).flatMap(epoch)
    } else {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return fs }
        let lines = data.split(separator: 10)
        fs.first = lines.lazy.compactMap(tsOf).first; fs.last = lines.reversed().lazy.compactMap(tsOf).first
        let needle = Data("\"tokens\"".utf8)
        recs = lines.filter { $0.range(of: needle) != nil }.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    var best: [String: (model: String, u: Usage, ts: Double)] = [:]
    for r in recs {
        guard r["type"] as? String == "gemini", let t = r["tokens"] as? [String: Any] else { continue }
        let cached = t["cached"] as? Int ?? 0
        let u = Usage(
            input: max(0, (t["input"] as? Int ?? 0) - cached) + (t["tool"] as? Int ?? 0),
            output: (t["output"] as? Int ?? 0) + (t["thoughts"] as? Int ?? 0), cacheWrite: 0, cacheRead: cached)
        best[r["id"] as? String ?? UUID().uuidString] = (r["model"] as? String ?? "gemini", u, (r["timestamp"] as? String).flatMap(epoch) ?? fs.first ?? 0)
    }
    fold(&fs, Array(best.values))
    return fs
}

func scanFile(_ url: URL, agent: String, size: Int, mtime: Double) -> FileStats {
    switch agent {
    case "codex": return scanCodex(url, size: size, mtime: mtime)
    case "gemini": return scanGemini(url, size: size, mtime: mtime)
    default: return scan(url, size: size, mtime: mtime)
    }
}

final class StatsStore: ObservableObject {
    static let shared = StatsStore()
    @Published var bySession: [String: FileStats] = [:]  // Project.id of a claude session -> totals (incl. its subagents)
    @Published var computing = false
    @Published var ledger: [String: FileStats] = [:] { didSet { lifetime = Lifetime(ledger) } }  // every session file ever scanned
    @Published var lifetime = Lifetime()
    @Published var dataStatus = ""
    var info: [String: String] = [:]  // session id -> project path
    private var cache: [String: FileStats] = [:]  // file path -> stats, keyed by size + mtime; touched only on `queue`
    private let queue = DispatchQueue(label: "stats", qos: .utility)
    private let cacheURL = cacheDir.appendingPathComponent("stats-v2.json")

    init() {
        cache = (try? JSONDecoder().decode([String: FileStats].self, from: Data(contentsOf: cacheURL))) ?? [:]
        ledger = cache
    }

    private func save() {
        if let d = try? JSONEncoder().encode(cache) { privateWrite(d, to: cacheURL) }
    }

    func export(to url: URL) {
        let e = StatsExport(exported: Date().timeIntervalSince1970, ledger: ledger)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try enc.encode(e).write(to: url); dataStatus = "Exported \(ledger.count) session files to \(url.lastPathComponent)." } catch {
            dataStatus = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Merge an export into the ledger: new session files are added; where both sides have one, the newer wins.
    func importStats(from url: URL) {
        guard let d = readCapped(url, max: maxImportBytes), let e = try? JSONDecoder().decode(StatsExport.self, from: d),
            ["ai-shelf", "AI Shelf", "Session Shelf"].contains(e.app),
            e.version == 1, e.ledger.count <= maxImportEntries
        else {
            dataStatus = "That file isn't an AI Shelf statistics export."; return
        }
        queue.async {
            let (added, updated) = self.merge(e)
            self.save()
            let snap = self.cache
            DispatchQueue.main.async {
                self.ledger = snap; self.dataStatus = "Imported \(added) new and \(updated) newer session files from \(url.lastPathComponent)."
            }
        }
    }

    var monthPrefix: String { String(dayFmt.string(from: Date()).prefix(7)) }

    var monthCost: (usd: Double, partial: Bool)? {
        var ms: [String: Usage] = [:]
        for (d, mm) in lifetime.all.days where d.hasPrefix(monthPrefix) { for (m, u) in mm { ms[m, default: Usage()] += u } }
        return cost(ms)
    }

    /// New tokens in the calendar week `back` weeks ago (0 = this week).
    func weekFresh(_ back: Int) -> Int {
        let cal = Calendar.current
        guard let start = cal.dateInterval(of: .weekOfYear, for: Date())?.start, let a = cal.date(byAdding: .day, value: -7 * back, to: start),
            let b = cal.date(byAdding: .day, value: 7, to: a)
        else { return 0 }
        let lo = dayFmt.string(from: a), hi = dayFmt.string(from: b)
        return lifetime.all.days.filter { $0.key >= lo && $0.key < hi }.values.reduce(0) { $0 + $1.values.reduce(Usage(), +).fresh }
    }

    /// One notification at 80% and one at 100% of the monthly budget.
    func checkBudget() {
        guard let b = Double(setting("monthlyBudget")), b > 0, let c = monthCost else { return }
        let key = "budgetAlert-" + monthPrefix
        let level = c.usd >= b ? 100 : c.usd >= b * 0.8 ? 80 : 0
        if level > UserDefaults.standard.integer(forKey: key) {
            UserDefaults.standard.set(level, forKey: key)
            notify(
                "AI Shelf budget",
                level == 100
                    ? "Estimated spend this month has reached your $\(Int(b)) budget." : "Estimated spend this month is at 80% of your $\(Int(b)) budget.")
        }
    }

    private func merge(_ e: StatsExport) -> (added: Int, updated: Int) {
        var added = 0, updated = 0
        for (k, v0) in e.ledger {
            // keys are session file names; skip anything else, and anything with absurd numbers
            guard k.count <= 256, !hasControl(k), !k.contains("/"), let v = v0.checked else { continue }
            if let c = cache[k] { if v.mtime > c.mtime { cache[k] = v; updated += 1 } } else { cache[k] = v; added += 1 }
        }
        return (added, updated)
    }

    /// Optional shared folder (iCloud Drive, Dropbox…): merge the file other Macs left there, then write ours back. Runs on `queue`.
    private func syncFile() {
        let dir = setting("syncFolder")
        guard !dir.isEmpty else { return }
        let u = URL(fileURLWithPath: dir).appendingPathComponent("ai-shelf-stats.json")
        if let d = readCapped(u, max: maxImportBytes), let e = try? JSONDecoder().decode(StatsExport.self, from: d), e.version == 1,
            e.ledger.count <= maxImportEntries
        {
            _ = merge(e); save()
        }
        if let d = try? JSONEncoder().encode(StatsExport(exported: Date().timeIntervalSince1970, ledger: cache)) {
            if (try? d.write(to: u, options: .atomic)) != nil { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path) }
        }
    }

    func summary(_ p: Project) -> Summary? {
        if p.sessionID != nil { return bySession[p.id]?.summary }
        var s = Summary(), any = false
        for k in p.children ?? [] { if let x = bySession[k.id]?.summary { s.add(x); any = true } }
        return any ? s : nil
    }

    /// Recompute in the background; the list appears immediately and numbers fill in as batches finish.
    func refresh(_ projects: [Project]) {
        guard pref("calcStats", true) else { return }
        let sessions = projects.flatMap { p in (p.children ?? []).filter { statsAgents.contains($0.agent) && $0.sessionID != nil }.map { (p.path, $0) } }
        if sessions.isEmpty { return }
        info = Dictionary(sessions.map { ($0.1.id, $0.0) }, uniquingKeysWith: { a, _ in a })
        computing = true
        queue.async {
            var batch: [String: FileStats] = [:], first = true
            func flush() {
                let b = batch; batch = [:]; let replace = first; first = false
                DispatchQueue.main.async { if replace { self.bySession = b } else { self.bySession.merge(b) { $1 } } }
            }
            for (path, s) in sessions {
                guard let main = s.trash.first else { continue }
                var files = [main]
                if s.agent == "claude", s.trash.count > 1 {
                    files +=
                        ((try? FileManager.default.contentsOfDirectory(at: s.trash[1].appendingPathComponent("subagents"), includingPropertiesForKeys: nil))
                        ?? [])
                        .filter { $0.pathExtension == "jsonl" }
                }
                var merged = FileStats()
                for f in files { merged.add(self.stats(for: f, project: path, agent: s.agent)) }
                batch[s.id] = merged
                if batch.count >= 12 { flush() }
            }
            flush()
            self.save()
            self.syncFile()
            let snap = self.cache
            DispatchQueue.main.async {
                self.ledger = snap; self.computing = false
                self.checkBudget()
            }
        }
    }

    /// Ledger key = the session file's own name (a uuid), not its path, so Fix Path moving a project never double-counts.
    /// Claude keys stay bare (as before); other agents are prefixed so their names can't collide.
    private func stats(for f: URL, project: String, agent: String) -> FileStats {
        let key = agent == "claude" ? f.lastPathComponent : "\(agent):\(f.lastPathComponent)"
        let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = v?.fileSize ?? 0, mt = v?.contentModificationDate?.timeIntervalSince1970 ?? 0
        if var c = cache[key], c.size == size, c.mtime == mt {
            if c.project != project || c.agent != agent { c.project = project; c.agent = agent; cache[key] = c }
            return c
        }
        var s = scanFile(f, agent: agent, size: size, mtime: mt)
        s.project = project; s.agent = agent
        cache[key] = s
        return s
    }
}
