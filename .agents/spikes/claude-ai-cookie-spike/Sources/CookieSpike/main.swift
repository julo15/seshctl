import AppKit
import Darwin
import WebKit

// Force line-buffered stdout so output appears immediately when piped to a file.
setvbuf(stdout, nil, _IOLBF, 0)

// Extra URLs passed on the command line are probed after the built-in list.
// Useful when DevTools surfaces an endpoint we wouldn't have guessed.
//   swift run CookieSpike https://claude.ai/v1/code/sessions/<id>/foo
let extraURLs: [String] = Array(CommandLine.arguments.dropFirst())

@MainActor
final class Spike: NSObject, WKNavigationDelegate {
    let window: NSWindow
    let webView: WKWebView
    let urlField: NSTextField
    var apiHit = false

    override init() {
        let windowWidth: CGFloat = 1000
        let windowHeight: CGFloat = 840
        let toolbarHeight: CGFloat = 40
        let contentRect = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        self.window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: contentRect)

        self.urlField = NSTextField(frame: NSRect(
            x: 10,
            y: windowHeight - toolbarHeight + 9,
            width: windowWidth - 80,
            height: 22
        ))
        urlField.placeholderString = "Paste the magic-link URL here, press Enter"

        let goButton = NSButton(frame: NSRect(
            x: windowWidth - 60,
            y: windowHeight - toolbarHeight + 6,
            width: 50,
            height: 28
        ))
        goButton.title = "Go"
        goButton.bezelStyle = .rounded

        let config = WKWebViewConfiguration()
        self.webView = WKWebView(frame: NSRect(
            x: 0,
            y: 0,
            width: windowWidth,
            height: windowHeight - toolbarHeight
        ), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15"

        contentView.addSubview(urlField)
        contentView.addSubview(goButton)
        contentView.addSubview(webView)
        window.contentView = contentView
        window.title = "Claude.ai Cookie Spike"
        window.center()
        window.level = .floating

        super.init()

        goButton.target = self
        goButton.action = #selector(goPressed)
        urlField.target = self
        urlField.action = #selector(goPressed)
        webView.navigationDelegate = self

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        print("→ Opened WKWebView at https://claude.ai/login")
        print("→ Sign in (or re-use the persisted WKWebsiteDataStore from a prior run).")
        print("→ Spike auto-detects login and runs the multi-endpoint sweep.")
        if !extraURLs.isEmpty {
            print("→ Extra URLs queued: \(extraURLs.count)")
        }
    }

    @objc func goPressed() {
        let raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw) else {
            print("❌ Not a valid URL: \(raw)")
            return
        }
        print("→ Navigating to pasted URL: \(url.absoluteString)")
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        print("↪ didFinish: \(url.absoluteString)")
        guard !apiHit else { return }
        Task { @MainActor in
            await self.runSweep()
        }
    }

    func runSweep() async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let all = await store.allCookies()
        let claudeCookies = all.filter { $0.domain.hasSuffix("claude.ai") }

        // Heuristic: logged in when BOTH sessionKey and sessionKeyLC are present.
        guard claudeCookies.contains(where: { $0.name == "sessionKey" }),
              claudeCookies.contains(where: { $0.name == "sessionKeyLC" }) else {
            return
        }
        apiHit = true

        print("\n=== Cookies for claude.ai (n=\(claudeCookies.count)) ===")
        for c in claudeCookies.sorted(by: { $0.name < $1.name }) {
            let preview = c.value.count > 12
                ? "\(c.value.prefix(8))…(len=\(c.value.count))"
                : c.value
            let exp = c.expiresDate.map { "\($0)" } ?? "session"
            print("  \(c.name)  httpOnly=\(c.isHTTPOnly)  secure=\(c.isSecure)  expires=\(exp)  domain=\(c.domain)")
            _ = preview
        }

        let cookieHeader = claudeCookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")

        // Per-call probe helper. Captures cookieHeader.
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.httpShouldSetCookies = false
        sessionConfig.httpCookieAcceptPolicy = .never
        let urlSession = URLSession(configuration: sessionConfig)

        // Set up output dir alongside the spike package root.
        let outDir = outputDirectory()
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            print("❌ Could not create output dir \(outDir.path): \(error)")
        }
        print("→ Dumping responses to \(outDir.path)")

        // 1. List endpoint — pull full response so we see every field.
        let listURL = "https://claude.ai/v1/code/sessions?limit=50"
        let listBody = await probe(urlString: listURL, cookieHeader: cookieHeader, session: urlSession, outDir: outDir, label: "01_list")

        // 2. Parse the list response for the first 3 session ids.
        let sessionIDs = parseSessionIDs(from: listBody, limit: 3)
        print("\n→ Picked session ids for detail probes: \(sessionIDs)")

        // 3. For each id, blind-probe candidate detail endpoint shapes.
        let detailPathTemplates = [
            "/v1/code/sessions/{id}",
            "/v1/code/sessions/{id}/messages",
            "/v1/code/sessions/{id}/messages?limit=50",
            "/v1/code/sessions/{id}/turns",
            "/v1/code/sessions/{id}/events",
            "/v1/code/sessions/{id}/history",
            "/v1/code/sessions/{id}/outcomes",
            "/v1/code/sessions/{id}/files",
            "/v1/code/sessions/{id}/summary",
        ]
        var probeIndex = 2
        for sid in sessionIDs {
            for tmpl in detailPathTemplates {
                let path = tmpl.replacingOccurrences(of: "{id}", with: sid)
                let urlStr = "https://claude.ai" + path
                let label = String(format: "%02d_%@", probeIndex, sanitize(path))
                _ = await probe(urlString: urlStr, cookieHeader: cookieHeader, session: urlSession, outDir: outDir, label: label)
                probeIndex += 1
            }
        }

        // 4. Replay any URLs passed on the command line (e.g. captured from DevTools).
        for raw in extraURLs {
            let label = String(format: "%02d_extra_%@", probeIndex, sanitize(URL(string: raw)?.path ?? raw))
            _ = await probe(urlString: raw, cookieHeader: cookieHeader, session: urlSession, outDir: outDir, label: label)
            probeIndex += 1
        }

        print("\n--- Done. Inspect responses in \(outDir.path) ---")
        print("    Tip: jq '. | keys' \(outDir.path)/01_list.json")
        fflush(stdout)
        exit(0)
    }

    /// Issue a GET against `urlString`, save body to `<outDir>/<label>.json`,
    /// and print a one-line summary. Returns the body data so the caller can
    /// parse it (e.g. to extract session ids from the list response).
    func probe(urlString: String, cookieHeader: String, session: URLSession, outDir: URL, label: String) async -> Data {
        guard let url = URL(string: urlString) else {
            print("\n=== \(label): \(urlString) ===")
            print("❌ Invalid URL")
            return Data()
        }
        var req = URLRequest(url: url)
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("managed-agents-2026-04-01", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        req.setValue("https://claude.ai/code", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        print("\n=== \(label): GET \(url.path)\(url.query.map { "?\($0)" } ?? "") ===")
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                print("❌ Non-HTTP response")
                return data
            }
            let ct = http.value(forHTTPHeaderField: "Content-Type") ?? "<none>"
            print("HTTP \(http.statusCode)  \(data.count) bytes  content-type=\(ct)")

            // Pretty-print JSON when possible so the file is easy to scan.
            let pretty: Data
            if let obj = try? JSONSerialization.jsonObject(with: data),
               let p = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                pretty = p
                if let topLevel = obj as? [String: Any] {
                    print("Top-level keys: \(topLevel.keys.sorted())")
                } else if let arr = obj as? [Any] {
                    print("Top-level: array (n=\(arr.count))")
                }
            } else {
                pretty = data
                let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<non-utf8>"
                print("Body preview (non-JSON):\n\(preview)")
            }

            let outFile = outDir.appendingPathComponent("\(label).json")
            try pretty.write(to: outFile)
            return data
        } catch {
            print("❌ Request failed: \(error)")
            return Data()
        }
    }

    /// Pulls a few session ids out of `/v1/code/sessions` response data.
    func parseSessionIDs(from data: Data, limit: Int) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]] else {
            return []
        }
        return arr.prefix(limit).compactMap { $0["id"] as? String }
    }

    /// Sanitize a path / URL string into a filesystem-friendly token.
    func sanitize(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                out.append(ch)
            } else if ch == "/" || ch == "?" || ch == "=" || ch == "&" {
                out.append("_")
            }
        }
        // Trim leading underscores from leading "/v1/..." path style.
        while out.first == "_" { out.removeFirst() }
        return out.isEmpty ? "x" : out
    }

    /// Output directory inside the spike folder (`out/` next to `Package.swift`).
    /// Falls back to CWD when source location isn't resolvable.
    func outputDirectory() -> URL {
        // #file → .../Sources/CookieSpike/main.swift  → spike root is two parents up.
        let source = URL(fileURLWithPath: #file)
        let spikeRoot = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return spikeRoot.appendingPathComponent("out")
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let spike = Spike()
    withExtendedLifetime(spike) {
        app.run()
    }
}
