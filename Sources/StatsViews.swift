import Charts
import SwiftUI

struct MenuView: View {
    @ObservedObject var m = Model.shared
    @Environment(\.openWindow) var openWindow
    @AppStorage(Pref.menuCount) var menuCount = 10

    var body: some View {
        ForEach(m.projects.prefix(menuCount)) { p in
            Button(p.name) { openProject(p) }.disabled(!p.exists)
        }
        Divider()
        Button("Reload") { m.reload() }
        Button("Open Manager") {
            openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
        }
        Button("Usage Stats") {
            openWindow(id: "stats"); NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Check for Updates…") {
            Updater.shared.check(); showSettings()
        }
        Button("Report a Bug…") { openIssue("bug_report.yml") }
        Button("Quit") { NSApp.terminate(nil) }
    }
}

struct StatCard: View {
    let title: String, value: String, caption: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Lifetime totals from the ledger (Claude, Codex and Gemini sessions, including ones the CLI has since expired or you deleted).
struct StatsCards: View {
    @ObservedObject var s = StatsStore.shared
    @ObservedObject var book = PriceBook.shared
    @AppStorage(Pref.prices) var prices = ""  // refresh when overrides change
    @AppStorage(Pref.monthlyBudget) var budgetText = ""

    var body: some View {
        let l = s.lifetime, a = l.all
        let spend = cost(a.models)
        let today = l.today, todayFresh = today.values.reduce(Usage(), +).fresh
        let top = a.models.max { $0.value.fresh < $1.value.fresh }
        let month = s.monthCost, budget = Double(budgetText) ?? 0
        let w0 = s.weekFresh(0), w1 = s.weekFresh(1)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("STATISTICS").font(.caption.weight(.semibold)).tracking(1.2)
                Text("all agents · lifetime").font(.caption).foregroundStyle(.secondary)
                if s.computing { ProgressView().controlSize(.mini) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 10)], spacing: 10) {
                StatCard(title: "Lifetime tokens", value: compact(a.total.fresh), caption: "\(compact(a.total.cacheRead)) cache reads")
                StatCard(
                    title: "Total spending", value: spend == nil ? "—" : money(spend),
                    caption: spend == nil ? "fetch prices in Settings" : spend!.partial ? "estimate, some unpriced" : "estimate, list prices")
                StatCard(title: "Sessions", value: "\(l.sessions)", caption: "\(l.projects) projects")
                StatCard(
                    title: "Active days", value: "\(a.days.count)",
                    caption: a.first.map { "since " + Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) } ?? "")
                StatCard(title: "Today", value: compact(todayFresh), caption: cost(today).map { money($0) + " est." } ?? "tokens")
                StatCard(
                    title: "This month", value: month == nil ? "—" : money(month),
                    caption: budget > 0 && month != nil ? "\(Int(month!.usd / budget * 100))% of $\(Int(budget)) budget" : "estimate")
                StatCard(
                    title: "This week", value: compact(w0),
                    caption: w1 > 0 ? String(format: "%+.0f%% vs last week", (Double(w0) / Double(w1) - 1) * 100) : "new tokens")
                StatCard(
                    title: "Top model", value: top?.key ?? "—",
                    caption: top.map { a.total.fresh > 0 ? "\(Int((Double($0.value.fresh) / Double(a.total.fresh) * 100).rounded()))% of tokens" : "" } ?? "")
            }
        }
    }
}

struct StatsView: View {
    @ObservedObject var s = StatsStore.shared
    @ObservedObject var book = PriceBook.shared
    @AppStorage(Pref.statsGroup) var group = "day"
    @AppStorage(Pref.prices) var prices = ""

    struct Row: Identifiable { let id: String; let usage: Usage; let cost: String }

    var rows: [Row] {
        var agg: [String: [String: Usage]] = [:]
        for (_, f) in s.ledger {
            switch group {
            case "day": for (d, ms) in f.days { for (m, u) in ms { agg[d, default: [:]][m, default: Usage()] += u } }
            case "week":
                for (d, ms) in f.days {
                    let k = dayFmt.date(from: d).flatMap { Calendar.current.dateInterval(of: .weekOfYear, for: $0)?.start }.map { dayFmt.string(from: $0) } ?? d
                    for (m, u) in ms { agg[k, default: [:]][m, default: Usage()] += u }
                }
            case "model": for (m, u) in f.models { agg[m, default: [:]][m, default: Usage()] += u }
            case "agent": for (m, u) in f.models { agg[f.agent ?? "claude", default: [:]][m, default: Usage()] += u }
            default: for (m, u) in f.models { agg[f.project ?? "(unknown)", default: [:]][m, default: Usage()] += u }
            }
        }
        let out = agg.map { Row(id: $0.key, usage: $0.value.values.reduce(Usage(), +), cost: money(cost($0.value))) }
        return ["day", "week"].contains(group) ? out.sorted { $0.id > $1.id } : out.sorted { $0.usage.fresh > $1.usage.fresh }
    }

    var body: some View {
        let data = rows
        VStack(alignment: .leading, spacing: 10) {
            StatsCards()
            HStack {
                Picker("Group by", selection: $group) {
                    Text("Day").tag("day"); Text("Week").tag("week"); Text("Project").tag("project"); Text("Agent").tag("agent"); Text("Model").tag("model")
                }
                .pickerStyle(.segmented).frame(width: 320)
                if s.computing { ProgressView().controlSize(.small); Text("Calculating…").foregroundStyle(.secondary) }
                if book.items.isEmpty && prices.isEmpty { Button("Fetch official prices") { book.refresh() } }
            }
            if ["day", "week"].contains(group) && !data.isEmpty {
                Chart(Array(data.prefix(30).reversed())) { r in
                    BarMark(x: .value("Day", r.id), y: .value("New tokens", r.usage.fresh))
                }.frame(height: 170)
            }
            Table(data) {
                TableColumn(group.capitalized) { Text($0.id) }
                TableColumn("New tokens") { Text($0.usage.fresh.formatted()).monospacedDigit() }.width(95)
                TableColumn("Input") { Text($0.usage.input.formatted()).monospacedDigit() }.width(85)
                TableColumn("Output") { Text($0.usage.output.formatted()).monospacedDigit() }.width(85)
                TableColumn("Cache write") { Text($0.usage.cacheWrite.formatted()).monospacedDigit() }.width(95)
                TableColumn("Cache read") { Text($0.usage.cacheRead.formatted()).monospacedDigit() }.width(105)
                TableColumn("Est. cost") { Text($0.cost).monospacedDigit() }.width(70)
            }
            Text(
                "New tokens = input + output + cache writes. Cache reads are context re-used from cache and are shown separately. Lifetime figures from every Claude, Codex and Gemini session file seen so far (Claude subagents included), even ones since expired or deleted. Antigravity doesn't record token counts. Cost is an estimate from the vendors' official list prices (Settings → Usage)."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding().frame(minWidth: 820, minHeight: 540)
        .onAppear {  // not tied to the agent picker: refreshes from Claude's history (cache makes this quick)
            DispatchQueue.global(qos: .utility).async {
                let ps = loadClaude(); DispatchQueue.main.async { s.refresh(ps) }
            }
        }
    }
}
