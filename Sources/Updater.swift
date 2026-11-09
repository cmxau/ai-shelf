import CryptoKit
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

/// Release downloads: https only, and only GitHub's own hosts (github.com redirects to the objects/release-assets CDN).
let updateHosts: Set<String> = ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]
func trustedAsset(_ u: URL) -> Bool { u.scheme == "https" && u.port == nil && u.user == nil && updateHosts.contains(u.host?.lowercased() ?? "") }

/// Every redirect hop of a download must stay on trusted hosts over https.
final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest q: URLRequest,
        completionHandler done: @escaping (URLRequest?) -> Void
    ) { done(q.url.map(trustedAsset) == true ? q : nil) }
}

let maxUpdateBytes = 200 << 20

/// Updates come from the GitHub releases of repoSlug: the newest release's .zip asset holds the app.
final class Updater: ObservableObject {
    static let shared = Updater()
    @Published var status = ""
    @Published var busy = false
    @Published var available: (version: String, zip: URL, page: URL, sha: String?)?

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
                let assets = o["assets"] as? [[String: Any]] ?? []
                let asset = assets.first {
                    ($0["browser_download_url"] as? String).flatMap(URL.init(string:)).map {
                        trustedAsset($0) && $0.path.hasPrefix("/\(repoSlug)/releases/download/")
                    } == true
                        && ($0["name"] as? String)?.hasSuffix(".zip") == true
                }
                let page =
                    (o["html_url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" && $0.host == "github.com" ? $0 : nil }
                    ?? URL(string: "https://github.com/\(repoSlug)/releases")!
                guard let asset, let zip = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else {
                    self.status = "Version \(v) is out, but the release has no .zip download."; return
                }
                // optional SHA-256: the digest GitHub computes for the asset ("sha256:<hex>"); never required
                let sha = (asset["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
                    .flatMap { $0.count == 64 && $0.allSatisfy(\.isHexDigit) ? $0 : nil }
                self.available = (v, zip, page, sha)
                self.status = "Version \(v) is available."
                if silent && !thenInstall { notify("AI Shelf update", "Version \(v) is available. Install it from Settings → About.") }
                if thenInstall { self.install() }
            }
        }.resume()
    }

    /// Download, unpack, then a detached script waits for this process to quit, swaps the app bundle and reopens it.
    func install() {
        guard let a = available, !busy, trustedAsset(a.zip) else { return }
        let dest = Bundle.main.bundleURL
        // never swap anything but our own installed .app
        guard dest.pathExtension == "app", dest.pathComponents.count >= 3, Bundle.main.bundleIdentifier == "com.cmxau.ai-shelf" else {
            status = "Not running from an installed AI Shelf.app. Download version \(a.version) manually."; return
        }
        guard FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            status = "Can't write to \(dest.deletingLastPathComponent().path). Download version \(a.version) manually."; return
        }
        busy = true; status = "Downloading \(a.version)…"
        let task = URLSession.shared.downloadTask(with: a.zip) { tmp, resp, err in
            var failure: String?
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("ai-shelf-update-\(UUID().uuidString)")
            let out = work.appendingPathComponent("x")  // empty directory the archive is unpacked into
            defer { if failure != nil { try? fm.removeItem(at: work) } }
            if let tmp {
                try? fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try? fm.createDirectory(at: out, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let zip = work.appendingPathComponent("u.zip"); try? fm.moveItem(at: tmp, to: zip)
                let n = (try? fm.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code != 200 || n < 1024 || n > maxUpdateBytes {
                    failure = "unexpected download (HTTP \(code), \(n) bytes)"
                } else if let want = a.sha, let d = try? Data(contentsOf: zip, options: .mappedIfSafe),
                    SHA256.hash(data: d).map({ String(format: "%02x", $0) }).joined() != want
                {
                    failure = "checksum mismatch"
                } else {
                    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-x", "-k", zip.path, out.path]
                    try? p.run(); p.waitUntilExit()
                    let app = (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil))?.first { $0.pathExtension == "app" }
                    let info = app.flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist")) }
                    if p.terminationStatus == 0, let app, fm.fileExists(atPath: app.appendingPathComponent("Contents/MacOS").path),
                        info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier
                    {
                        // arguments, not interpolation: nothing in the paths is ever parsed as shell. The old app is renamed aside and
                        // only deleted once the new one is in place; if the move fails it is put back.
                        let script = """
                            while kill -0 "$1" 2>/dev/null; do sleep 0.3; done
                            B="$2.old-$1"
                            if mv "$2" "$B"; then
                              if mv "$3" "$2"; then rm -rf "$B"; else mv "$B" "$2"; fi
                            fi
                            case "$4" in */ai-shelf-update-*) rm -rf "$4";; esac
                            open "$2"
                            """
                        let s = Process(); s.executableURL = URL(fileURLWithPath: "/bin/sh")
                        s.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), dest.path, app.path, work.path]
                        try? s.run()
                        DispatchQueue.main.async { NSApp.terminate(nil) }
                        return
                    }
                    failure = "The download didn't contain an AI Shelf app."
                }
            } else {
                failure = err?.localizedDescription ?? "download failed"
            }
            DispatchQueue.main.async {
                self.busy = false; self.status = "Update failed: \(failure ?? "")"
            }
        }
        task.delegate = RedirectGuard()
        task.resume()
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
