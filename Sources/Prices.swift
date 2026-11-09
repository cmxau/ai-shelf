import SwiftUI

// MARK: - Prices

/// Your own lines (Settings → Usage) override the fetched official prices. One line per model:
/// "name-fragment input output cacheWrite cacheRead", USD per million tokens. The longest matching name wins.
var userPricesMemo: (raw: String, table: [(String, [Double])]) = ("\u{0}", [])
func userPrices() -> [(String, [Double])] {
    let raw = setting("prices")
    if raw != userPricesMemo.raw {
        userPricesMemo = (
            raw,
            raw.split(whereSeparator: \.isNewline).compactMap { line -> (String, [Double])? in
                let w = line.split(whereSeparator: \.isWhitespace).map(String.init)
                let n = w.dropFirst().compactMap(Double.init)
                return w.count == 5 && n.count == 4 && n.allSatisfy({ $0.isFinite && $0 >= 0 }) ? (w[0].lowercased(), n) : nil
            }
        )
    }
    return userPricesMemo.table
}

func priceFor(_ model: String) -> [Double]? {
    let m = model.lowercased()
    func best(_ t: [(String, [Double])]) -> [Double]? { t.filter { m.contains($0.0) }.max { $0.0.count < $1.0.count }?.1 }
    return best(userPrices()) ?? best(PriceBook.shared.table)
}

func cost(_ models: [String: Usage]) -> (usd: Double, partial: Bool)? {
    if userPrices().isEmpty && PriceBook.shared.items.isEmpty { return nil }
    var usd = 0.0, partial = false
    for (model, u) in models {
        guard let t = priceFor(model) else { partial = true; continue }
        usd += (Double(u.input) * t[0] + Double(u.output) * t[1] + Double(u.cacheWrite) * t[2] + Double(u.cacheRead) * t[3]) / 1e6
    }
    return (usd, partial)
}

// MARK: - Official price sources (vendors' own pricing pages, markdown versions)

struct PriceEntry: Codable { var p: [Double]; var src: String }  // p = input, output, cache write, cache read ($ / MTok)
struct PriceRow: Identifiable { let id: String; let src: String; let p: [Double] }

let dollarRE = try! NSRegularExpression(pattern: #"\$([0-9]+(?:\.[0-9]+)?)"#)
func dollar(_ s: String) -> Double? {
    guard let m = dollarRE.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
    return Double(s[r])
}
func tableCells(_ line: Substring) -> [String] {
    line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
}

/// Anthropic: "Model pricing" table. 5-minute cache-write price is used (usage doesn't split 5m/1h writes);
/// Haiku 5.5 uses its "up to 100,000 tokens" tier.
func parseAnthropic(_ md: String) -> [String: [Double]] {
    var out: [String: [Double]] = [:], cols: [String: Int] = [:]
    for line in md.split(separator: "\n") where line.hasPrefix("|") {
        let c = tableCells(line)
        if c.first == "Model" {
            cols = [:]
            for (i, h) in c.enumerated() {
                let l = h.lowercased()
                if l.contains("base input") {
                    cols["in"] = i
                } else if l.contains("5m cache") {
                    cols["cw"] = i
                } else if l.contains("cache hits") {
                    cols["cr"] = i
                } else if l == "output tokens" {
                    cols["out"] = i
                }
            }
            continue
        }
        guard cols.count == 4, c.count > cols.values.max()!, c[0].hasPrefix("Claude"),
            let i = dollar(c[cols["in"]!]), let o = dollar(c[cols["out"]!]), let w = dollar(c[cols["cw"]!]), let r = dollar(c[cols["cr"]!])
        else { continue }
        let id = (c[0].components(separatedBy: " (").first ?? c[0]).lowercased().replacingOccurrences(of: ".", with: "-").replacingOccurrences(
            of: " ", with: "-")
        if out[id] == nil { out[id] = [i, o, w, r] }  // first row wins (Haiku's short-prompt tier)
    }
    return out
}

/// OpenAI: the Standard-tier text-model tables (short-context prices) plus the Codex rows. No price listed for a
/// cached read / write means it's billed at the input price.
func parseOpenAI(_ md: String) -> [String: [Double]] {
    var out: [String: [Double]] = [:]
    if let start = md.range(of: "### Standard pricing data") {
        var body = md[start.upperBound...]
        if let end = body.range(of: "\n### ") { body = body[..<end.lowerBound] }
        var cols: [String: Int] = [:]
        for line in body.split(separator: "\n") where line.hasPrefix("|") {
            let c = tableCells(line)
            if c.first == "Model" {
                cols = [:]
                for (i, h) in c.enumerated() {
                    switch h.lowercased() {
                    case "input", "short context input": cols["in"] = i
                    case "output", "short context output": cols["out"] = i
                    case "cached input", "short context cached input": cols["cr"] = i
                    case "short context 30m write": cols["cw"] = i
                    default: break
                    }
                }
                continue
            }
            guard let ii = cols["in"], let oi = cols["out"], c.count > max(ii, oi), let name = c.first?.components(separatedBy: " (").first?.lowercased(),
                let i = dollar(c[ii]), let o = dollar(c[oi])
            else { continue }
            let cr = cols["cr"].flatMap { $0 < c.count ? dollar(c[$0]) : nil } ?? i
            let cw = cols["cw"].flatMap { $0 < c.count ? dollar(c[$0]) : nil } ?? i
            if out[name] == nil { out[name] = [i, o, cw, cr] }
        }
    }
    let codex = try! NSRegularExpression(pattern: #"\| Codex \| ([a-z0-9.\-]+) \| \$([0-9.]+) \| \$([0-9.]+) \| \$([0-9.]+) \|"#)
    for m in codex.matches(in: md, range: NSRange(md.startIndex..., in: md)) {
        let g = (1...4).compactMap { Range(m.range(at: $0), in: md).map { String(md[$0]) } }
        // first occurrence = standard tier
        if g.count == 4, out[g[0]] == nil, let i = Double(g[1]), let o = Double(g[2]), let r = Double(g[3]) { out[g[0]] = [i, o, i, r] }
    }
    return out
}

/// Google: one section per model; the "Standard" tab's paid-tier column. Where a cell lists dated prices
/// ("through Dec 31, 2026" / "starting Jan 1, 2027") the one in effect today is used; where it lists
/// prompt-size tiers, the first (<= 200k tokens). Context caching has no write fee, so cache write = input price.
func parseGoogle(_ md: String, today: Date = Date()) -> [String: [Double]] {
    let dateRE = try! NSRegularExpression(pattern: #"(through|starting) ([A-Z][a-z]+ [0-9]{1,2}, [0-9]{4})"#)
    let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "MMMM d, yyyy"
    func price(_ cell: String) -> Double? {
        let lines = cell.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("$") }
        var valid: Double? = nil, sawDated = false
        for l in lines {
            guard let m = dateRE.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), let kr = Range(m.range(at: 1), in: l),
                let dr = Range(m.range(at: 2), in: l),
                let d = df.date(from: String(l[dr]))
            else { continue }
            sawDated = true
            let inEffect = l[kr] == "through" ? today <= d.addingTimeInterval(86_400) : today >= d
            if inEffect, valid == nil { valid = dollar(l) }
        }
        return sawDated ? valid : lines.first.flatMap(dollar)
    }
    var out: [String: [Double]] = [:]
    let skip = ["image", "tts", "live", "transcribe", "embedding", "audio", "lyria", "robotics", "translate", "omni", "gemma"]
    for sec in md.components(separatedBy: "\n## ").dropFirst() {
        guard let idr = sec.range(of: #"\*\[`([^`]+)`\]"#, options: .regularExpression),
            let tab = sec.range(of: #"{% tab title="Standard" %}"#), let end = sec.range(of: "{% /tab %}", range: tab.upperBound..<sec.endIndex)
        else { continue }
        let id = String(sec[idr].dropFirst(3).dropLast(2))
        if skip.contains(where: id.contains) { continue }
        var rows: [String: String] = [:]
        for chunk in sec[tab.upperBound..<end.lowerBound].components(separatedBy: "\n  ---") {
            var cells: [String] = []
            for l in chunk.split(separator: "\n") {
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("* ") { cells.append(String(t.dropFirst(2))) } else if !cells.isEmpty { cells[cells.count - 1] += "\n" + t }
            }
            if cells.count >= 3 { rows[cells[0].lowercased()] = cells[2] }
        }
        guard let i = rows["input price"].flatMap(price), let o = rows.first(where: { $0.key.hasPrefix("output price") })?.value, let op = price(o) else {
            continue
        }
        out[id] = [i, op, i, rows["context caching price"].flatMap(price) ?? i]
    }
    return out
}

final class PriceBook: ObservableObject {
    static let shared = PriceBook()
    @Published var items: [String: PriceEntry] = [:] { didSet { table = items.map { ($0.key.lowercased(), $0.value.p) } } }
    @Published var fetched: Date?
    @Published var status = ""
    @Published var busy = false
    private(set) var table: [(String, [Double])] = []
    private let file = cacheDir.appendingPathComponent("prices.json")
    struct Saved: Codable { var fetched: Double; var items: [String: PriceEntry] }

    init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            items = s.items; fetched = Date(timeIntervalSince1970: s.fetched)
            table = items.map { ($0.key.lowercased(), $0.value.p) }
        }
    }

    var rows: [PriceRow] { items.map { PriceRow(id: $0.key, src: $0.value.src, p: $0.value.p) }.sorted { ($0.src, $0.id) < ($1.src, $1.id) } }

    func refreshIfStale() {
        if pref("autoPrices", true), fetched.map({ Date().timeIntervalSince($0) > 7 * 86_400 }) ?? true { refresh() }
    }

    /// Fetch every vendor in parallel. A vendor that fails keeps its previous prices, so a layout change on one page never wipes the rest.
    func refresh() {
        guard !busy else { return }
        busy = true; status = "Fetching official prices…"
        let sources: [(String, String, (String) -> [String: [Double]])] = [
            ("Anthropic", "https://platform.claude.com/docs/en/about-claude/pricing.md", parseAnthropic),
            ("OpenAI", "https://developers.openai.com/api/docs/pricing.md", { parseOpenAI($0) }),
            ("Google", "https://ai.google.dev/gemini-api/docs/pricing.md.txt", { parseGoogle($0) }),
        ]
        var got: [String: (items: [String: [Double]], note: String)] = [:]
        let group = DispatchGroup(), lock = NSLock()
        for (name, url, parse) in sources {
            group.enter()
            var req = URLRequest(url: URL(string: url)!)
            req.setValue("Mozilla/5.0 ai-shelf", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { data, resp, err in
                defer { group.leave() }
                var r: (items: [String: [Double]], note: String)
                if let data, (resp as? HTTPURLResponse)?.statusCode == 200, data.count <= 8 << 20 {
                    // untrusted page: keep only plausible prices ($/MTok, finite, 0...10000) under short model names
                    let items = parse(String(decoding: data, as: UTF8.self)).filter {
                        $0.key.count <= 100 && $0.value.count == 4 && $0.value.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 10_000 }
                    }
                    r = (items, items.isEmpty ? "page format not recognised" : "\(items.count) models")
                } else {
                    r = ([:], err?.localizedDescription ?? "HTTP error")
                }
                lock.lock(); got[name] = r; lock.unlock()
            }.resume()
        }
        group.notify(queue: .main) {
            var merged = self.items, notes: [String] = []
            for (name, _, _) in sources {
                guard let r = got[name] else { continue }
                if r.items.isEmpty { notes.append("\(name): failed (\(r.note)), kept previous"); continue }
                merged = merged.filter { $0.value.src != name }
                for (k, v) in r.items { merged[k] = PriceEntry(p: v, src: name) }
                notes.append("\(name): \(r.note)")
            }
            self.items = merged
            if notes.contains(where: { !$0.contains("failed") }) { self.fetched = Date() }
            self.status = notes.joined(separator: " · ") + (self.fetched.map { " — updated \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
            self.busy = false
            if let d = try? JSONEncoder().encode(Saved(fetched: self.fetched?.timeIntervalSince1970 ?? 0, items: self.items)) { privateWrite(d, to: self.file) }
        }
    }
}

func money(_ c: (usd: Double, partial: Bool)?) -> String { c.map { String(format: "$%.2f", $0.usd) + ($0.partial ? "+" : "") } ?? "" }
func compact(_ n: Int) -> String { n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
func stamp(_ t: Double) -> String { Date(timeIntervalSince1970: t).formatted(date: .abbreviated, time: .shortened) }
