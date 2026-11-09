import Carbon
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Launching

func sh(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
/// AppleScript string body. Control characters (a newline would run a second command in the terminal) become spaces.
func osa(_ s: String) -> String {
    String(s.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? " " : Character($0) }).replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}
func hasControl(_ s: String) -> Bool { s.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
func run(_ exe: String, _ args: [String]) { let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args; try? p.run() }
func osascript(_ lines: [String]) { run("/usr/bin/osascript", lines.flatMap { ["-e", $0] }) }

// ponytail: built-in CLIs we know, plus any names the user adds in Settings. "Installed" = found by the user's login shell.
let builtinAgents = ["claude", "agy", "codex", "gemini", "opencode", "aider", "goose", "amp", "cursor-agent", "copilot"]
var checkedAgents: [String: Bool] = [:]

func customAgents() -> [String] {
    setting(Pref.customAgents).split(whereSeparator: \.isNewline)
        .compactMap { $0.split(separator: " ").first.map(String.init) }
        .filter { isAgentName($0) && !builtinAgents.contains($0) }
}
/// A command name: ASCII letters, digits, "-", "_", "." (never a leading "-" or "."), so it can't be an option or carry shell syntax.
func isAgentName(_ s: String) -> Bool {
    s.utf8.count <= 64 && s.first.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true
        && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
}
func catalog() -> [String] { builtinAgents + customAgents() }
func disabledAgents() -> Set<String> { Set(setting(Pref.disabledAgents).split(separator: ",").map(String.init)) }

/// One login-shell call for every name not checked yet.
func detectAgents(_ names: [String]) {
    let todo = names.filter { checkedAgents[$0] == nil }
    guard !todo.isEmpty else { return }
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = [
        "-lic", "for a in \(todo.filter(isAgentName).map(sh).joined(separator: " ")); do command -v -- \"$a\" >/dev/null 2>&1 && echo \"HAVE $a\"; done",
    ]
    p.standardOutput = out; p.standardError = FileHandle.nullDevice
    try? p.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    let have = Set(text.split(whereSeparator: \.isNewline).compactMap { $0.hasPrefix("HAVE ") ? String($0.dropFirst(5)) : nil })
    for a in todo { checkedAgents[a] = have.contains(a) }
}

func isActive(_ a: String) -> Bool { detectAgents([a]); return checkedAgents[a] == true && !disabledAgents().contains(a) }
func activeAgents() -> [String] { detectAgents(catalog()); return catalog().filter(isActive) }

/// Extra flags from Settings, one line per agent: "claude --dangerously-skip-permissions".
func extraFlags(_ agent: String) -> String {
    setting(Pref.agentFlags).split(whereSeparator: \.isNewline).compactMap { line -> String? in
        let w = line.split(separator: " ", maxSplits: 1)
        return w.count == 2 && String(w[0]) == agent ? String(w[1]) : nil
    }.joined(separator: " ")
}

let terminals = ["Terminal", "iTerm", "Ghostty", "WezTerm", "Alacritty"].filter { t in
    t == "Terminal" || ["/Applications", home.path + "/Applications"].contains { FileManager.default.fileExists(atPath: "\($0)/\(t).app") }
}

// only agents whose history we list have session rows
let resumeFlag = ["claude": "--resume", "agy": "--conversation", "codex": "resume", "gemini": "--resume"]

/// Opens a project (or one session of it) in the chosen terminal with the chosen CLI.
func openProject(_ p: Project) {
    let d = UserDefaults.standard
    let cli = !p.agent.isEmpty ? p.agent : d.string(forKey: Pref.cli) ?? "claude"
    // path and session id come from files on disk (a session's recorded cwd / id): refuse anything that isn't a plain absolute path / token
    guard isAgentName(cli), p.path.hasPrefix("/"), !hasControl(p.path) else {
        Model.shared.error = "Won't open: \(oneLine(p.path)) isn't a valid folder path."; return
    }
    let flags = extraFlags(cli)
    let resume = p.sessionID.flatMap { id in resumeFlag[cli].map { " \($0) \(sh(id))" } } ?? ""
    let cmd = cli + (flags.isEmpty ? "" : " " + flags) + resume
    let line = "cd \(sh(p.path)) && \(cmd)"
    let inShell = ["zsh", "-lic", cmd]  // GUI apps lack the shell PATH, so go through a login shell
    switch d.string(forKey: Pref.terminal) ?? "Terminal" {
    case "iTerm":
        osascript([
            "tell application \"iTerm\"", "activate",
            pref(Pref.openInTab, false)
                ? "if (count of windows) = 0 then create window with default profile else tell current window to create tab with default profile"
                : "create window with default profile",
            "tell current session of current window to write text \"\(osa(line))\"", "end tell",
        ])
    case "Ghostty": run("/usr/bin/open", ["-na", "Ghostty", "--args", "--working-directory=" + p.path, "-e"] + inShell)
    case "WezTerm": run("/usr/bin/open", ["-na", "WezTerm", "--args", "start", "--cwd", p.path, "--"] + inShell)
    case "Alacritty": run("/usr/bin/open", ["-na", "Alacritty", "--args", "--working-directory", p.path, "-e"] + inShell)
    default:
        osascript(["tell application \"Terminal\" to activate", "tell application \"Terminal\" to do script \"\(osa(line))\""])
    }
}

func realPath(_ p: String) -> String {
    guard let r = realpath(p, nil) else { return p }
    defer { free(r) }
    return String(cString: r)
}

func capture(_ exe: String, _ args: [String]) -> String {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    p.standardOutput = out; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let d = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
}

/// The conversation as (role, text) pairs, for Markdown export. nil = this agent's format can't be read (agy keeps conversations in binary DBs).
func transcript(_ p: Project) -> [(String, String)]? {
    guard p.sessionID != nil, let f = p.trash.first, let data = readCapped(f, max: 256 << 20) else { return nil }
    let text = String(decoding: data, as: UTF8.self)
    switch p.agent {
    case "claude": return text.split(separator: "\n").compactMap(msg).map { ($0.role, $0.text) }
    case "codex":
        return text.split(separator: "\n").compactMap(jsonObj).compactMap { o in
            guard let pl = o["payload"] as? [String: Any], let m = pl["message"] as? String, !m.hasPrefix("<") else { return nil }
            switch pl["type"] as? String {
            case "user_message": return ("user", m)
            case "agent_message": return ("assistant", m)
            default: return nil
            }
        }
    case "gemini":
        return geminiRecords(f).compactMap { o in
            let t = partsText(o["content"])
            switch o["type"] as? String {
            case "user": return t.isEmpty ? nil : ("user", t)
            case "gemini": return t.isEmpty ? nil : ("assistant", t)
            default: return nil
            }
        }
    default: return nil
    }
}

func exportTranscript(_ p: Project) {
    guard let t = transcript(p), !t.isEmpty else {
        Model.shared.error = "Export as Markdown isn't available for this session (\(p.agent) keeps no readable transcript)."; return
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    let safe = String(p.title.prefix(40)).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    panel.nameFieldStringValue = (safe.isEmpty ? "session" : safe) + ".md"
    guard panel.runModal() == .OK, let u = panel.url else { return }
    var md = "# \(p.title)\n\n`\(p.path)` · \(p.agent) · \(p.modified.formatted(date: .abbreviated, time: .shortened))\n\n"
    for (role, text) in t { md += "## \(role == "user" ? "You" : "Assistant")\n\n\(text)\n\n" }
    try? md.write(to: u, atomically: true, encoding: .utf8)
}

func notify(_ title: String, _ body: String) {
    guard pref(Pref.notify, true) else { return }
    let c = UNUserNotificationCenter.current()
    c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
        guard ok else {
            osascript(["display notification \"\(osa(body))\" with title \"\(osa(title))\""]); return
        }
        let n = UNMutableNotificationContent()
        n.title = title; n.body = body
        c.add(UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil))
    }
}

/// System-wide shortcut (Control-Option-S) that brings the window forward with the search box open.
enum HotKey {
    static var ref: EventHotKeyRef?
    static var installed = false

    static func update() {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, _ in
                    DispatchQueue.main.async { showQuickSearch() }
                    return noErr
                }, 1, &spec, nil, nil)
            installed = true
        }
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
        if pref(Pref.hotkey, true) {
            RegisterEventHotKey(
                UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x4149_5348, id: 1), GetApplicationEventTarget(), 0, &ref)
        }
    }
}

func showQuickSearch() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first { $0.title == "AI Shelf" }?.makeKeyAndOrderFront(nil)
    Model.shared.searchOpen = true
}
