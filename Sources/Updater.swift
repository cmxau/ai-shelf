import SwiftUI

/// "1.2.10" vs "1.2.9": numeric, component by component.
func isNewer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
        if p != q { return p > q }
    }
    return false
}

/// Updates come from the GitHub releases of repoSlug: the newest release's .zip asset holds the app.
final class Updater: ObservableObject {
    static let shared = Updater()
    @Published var status = ""
    @Published var busy = false
    @Published var available: (version: String, zip: URL, page: URL)?

    func check(thenInstall: Bool = false, silent: Bool = false) {
        guard !busy else { return }
        busy = true
        if !silent { status = "Checking…" }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let o = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                self.busy = false
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                guard code == 200, let o, let tag = o["tag_name"] as? String else {
                    if !silent {
                        self.status =
                            code == 404 ? "No releases are published yet." : "Couldn't check for updates: \(err?.localizedDescription ?? "HTTP \(code)")."
                    }
                    return
                }
                let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                guard isNewer(v, than: appVersion) else {
                    self.available = nil; if !silent { self.status = "You're up to date (version \(appVersion))." }; return
                }
                let zip = (o["assets"] as? [[String: Any]])?.compactMap { $0["browser_download_url"] as? String }.first { $0.hasSuffix(".zip") }
                let page = (o["html_url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://github.com/\(repoSlug)/releases")!
                guard let zip = zip.flatMap(URL.init(string:)) else { self.status = "Version \(v) is out, but the release has no .zip download."; return }
                self.available = (v, zip, page)
                self.status = "Version \(v) is available."
                if silent && !thenInstall { notify("AI Shelf update", "Version \(v) is available. Install it from Settings → About.") }
                if thenInstall { self.install() }
            }
        }.resume()
    }

    /// Download, unpack, then a detached script waits for this process to quit, swaps the app bundle and reopens it.
    func install() {
        guard let a = available, !busy else { return }
        let dest = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            status = "Can't write to \(dest.deletingLastPathComponent().path). Download version \(a.version) manually."; return
        }
        busy = true; status = "Downloading \(a.version)…"
        URLSession.shared.downloadTask(with: a.zip) { tmp, _, err in
            var failure: String?
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("ai-shelf-update-\(UUID().uuidString)")
            if let tmp {
                try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("u.zip"); try? FileManager.default.moveItem(at: tmp, to: zip)
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-x", "-k", zip.path, work.path]
                try? p.run(); p.waitUntilExit()
                let app = (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil))?.first { $0.pathExtension == "app" }
                if let app, FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS").path) {
                    let script =
                        "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done; rm -rf \(sh(dest.path)) && mv \(sh(app.path)) \(sh(dest.path)) && open \(sh(dest.path))"
                    let s = Process(); s.executableURL = URL(fileURLWithPath: "/bin/sh"); s.arguments = ["-c", script]
                    try? s.run()
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                    return
                }
                failure = "The download didn't contain an app."
            } else {
                failure = err?.localizedDescription ?? "download failed"
            }
            DispatchQueue.main.async {
                self.busy = false; self.status = "Update failed: \(failure ?? "")"
            }
        }.resume()
    }

    /// Launch-time hook: check at most once a day when enabled; install straight away if that's enabled too.
    func launchCheck() {
        guard pref("autoCheckUpdates", true) else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        if Date().timeIntervalSince1970 - last > 86_400 { check(thenInstall: pref("autoInstallUpdates", false), silent: true) }
    }
}

func openIssue(_ template: String) {
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    var c = URLComponents(string: "https://github.com/\(repoSlug)/issues/new")!
    c.queryItems = [URLQueryItem(name: "template", value: template), URLQueryItem(name: "version", value: appVersion), URLQueryItem(name: "macos", value: os)]
    NSWorkspace.shared.open(c.url!)
}

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
