import AppKit
import ServiceManagement
import os

private let log = Logger(subsystem: "com.farhad.codexusage", category: "ui")

struct UsageSnapshot {
    let plan: String
    let statusCode: Int
    let ok: Bool
    let primaryPct: Int
    let primaryReset: String
    let secondaryPct: Int
    let secondaryReset: String
}

enum FetchResult {
    case success(UsageSnapshot)
    case failure(String)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var usage: UsageSnapshot?
    private var errorMessage: String?
    private var lastFetch: Date?
    private var inFlight = false
    private var timer: Timer?
    private var wakeObserver: Any?
    private let fetchQueue = DispatchQueue(label: "com.farhad.codexusage.fetch", qos: .utility)
    private static let refreshInterval: TimeInterval = 300

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = "codex …"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        render()

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    // MARK: - Refresh

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        fetchQueue.async { [weak self] in
            let result = Self.fetch()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                self.lastFetch = Date()
                switch result {
                case .success(let snapshot):
                    self.usage = snapshot
                    self.errorMessage = nil
                case .failure(let message):
                    self.errorMessage = message
                }
                self.render()
            }
        }
    }

    /// Locate the CLI. Prefers the fnm "default" alias bin (stable across node version
    /// switches), then concrete fnm versions, then common PATH locations, and finally
    /// falls back to the user's interactive zsh so the `usagecodex` alias resolves.
    nonisolated private static func resolveBinary() -> (path: String, dir: String)? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates: [String] = [
            home + "/.local/share/fnm/aliases/default/bin/opencode-codex-usage",
            "/opt/homebrew/bin/opencode-codex-usage",
            "/usr/local/bin/opencode-codex-usage",
            home + "/.local/bin/opencode-codex-usage",
        ]
        let versionsDir = home + "/.local/share/fnm/node-versions"
        if let versions = try? fm.contentsOfDirectory(atPath: versionsDir) {
            for version in versions.sorted(by: >) {
                candidates.insert(
                    "\(versionsDir)/\(version)/installation/bin/opencode-codex-usage",
                    at: 1
                )
            }
        }
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return (candidate, (candidate as NSString).deletingLastPathComponent)
        }
        return nil
    }

    nonisolated private static func fetch() -> FetchResult {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let basePATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if let bin = resolveBinary() {
            return run(
                [bin.path, "--json", "--opencode", "1", "--no-notify"],
                env: ["PATH": "\(bin.dir):\(basePATH)", "HOME": home]
            )
        }
        // Last resort: the user's interactive shell, where the `usagecodex` alias lives.
        return run(
            ["/bin/zsh", "-ic", "usagecodex --json --opencode 1 --no-notify"],
            env: ["PATH": basePATH, "HOME": home]
        )
    }

    nonisolated private static func run(_ args: [String], env: [String: String]) -> FetchResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        process.environment = env
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return .failure("Could not launch usage CLI: \(error.localizedDescription)")
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let detail = errText.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure("usage CLI exited \(process.terminationStatus)\(detail.isEmpty ? "" : ": \(detail)")")
        }
        return parse(output)
    }

    /// Pulls the JSON object out of the output (tolerates shell noise around it).
    nonisolated private static func jsonSlice(_ text: String) -> Data? {
        guard
            let start = text.firstIndex(of: "{"),
            let end = text.lastIndex(of: "}"),
            start < end
        else { return nil }
        return String(text[start...end]).data(using: .utf8)
    }

    nonisolated private static func parse(_ text: String) -> FetchResult {
        guard let data = jsonSlice(text) else {
            return .failure("No JSON in usage CLI output")
        }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let used = root["used"] as? [String: Any]
        else {
            return .failure("Could not parse usage JSON")
        }
        let reset = root["reset"] as? [String: String] ?? [:]
        func pct(_ key: String) -> Int {
            guard let n = used[key] as? NSNumber else { return 0 }
            return min(100, n.intValue)
        }
        return .success(UsageSnapshot(
            plan: root["plan"] as? String ?? "-",
            statusCode: (root["statusCode"] as? NSNumber)?.intValue ?? 0,
            ok: (root["status"] as? String) == "ok",
            primaryPct: pct("primary"),
            primaryReset: reset["primary"] ?? "?",
            secondaryPct: pct("secondary"),
            secondaryReset: reset["secondary"] ?? "?"
        ))
    }

    // MARK: - UI

    private func render() {
        updateButton()
        rebuildMenu()
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        if let usage {
            let title = NSMutableAttributedString()
            title.append(NSAttributedString(string: "codex 7dW "))
            let color: NSColor = usage.primaryPct >= 80
                ? .systemRed : usage.primaryPct >= 50 ? .systemOrange : .systemGreen
            title.append(NSAttributedString(
                string: "\(usage.primaryPct)%",
                attributes: [.foregroundColor: color]
            ))
            title.append(NSAttributedString(string: "  ⏳ \(usage.primaryReset)"))
            button.attributedTitle = title
            button.toolTip = "Codex quota — updated \(Self.timeString(lastFetch))"
            log.info("status title: \(title.string, privacy: .public)")
        } else if let errorMessage {
            button.title = "codex ⚠️"
            button.toolTip = "Codex quota — \(errorMessage)"
            log.error("status error: \(errorMessage, privacy: .public)")
        } else {
            button.title = "codex …"
            button.toolTip = "Codex quota — updating…"
        }
    }

    private static func timeString(_ date: Date?) -> String {
        guard let date else { return "never" }
        return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let header: String
        if let usage {
            header = "Codex Usage — plan \(usage.plan) · HTTP \(usage.statusCode)\(usage.ok ? "" : " ⚠️")"
        } else if errorMessage != nil {
            header = "Codex Usage — update failed"
        } else {
            header = "Codex Usage — updating…"
        }
        addInfo(header)
        menu.addItem(.separator())

        if let usage {
            addInfo(
                "7d window  \(bar(usage.primaryPct)) \(usage.primaryPct)%  resets in \(usage.primaryReset)",
                monospaced: true
            )
            addInfo(
                "window B   \(bar(usage.secondaryPct)) \(usage.secondaryPct)%  resets in \(usage.secondaryReset)",
                monospaced: true
            )
            menu.addItem(.separator())
        } else if let errorMessage {
            let message = errorMessage.count > 90 ? String(errorMessage.prefix(90)) + "…" : errorMessage
            addInfo(message)
            menu.addItem(.separator())
        }

        _ = addAction("Refresh Now", action: #selector(refreshNow), key: "r")
        if #available(macOS 13.0, *) {
            let login = addAction("Launch at Login", action: #selector(toggleLogin), key: "")
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        menu.addItem(.separator())
        _ = addAction("Quit CodexUsage", action: #selector(quit), key: "q")
    }

    private func addInfo(_ title: String, monospaced: Bool = false) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if monospaced {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
            )
        }
        menu.addItem(item)
    }

    private func addAction(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
        return item
    }

    private func bar(_ pct: Int) -> String {
        let width = 16
        let filled = max(0, min(width, pct * width / 100))
        return "[" + String(repeating: "#", count: filled) + String(repeating: "-", count: width - filled) + "]"
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let last = lastFetch, Date().timeIntervalSince(last) < 45 { return }
        refresh()
    }

    // MARK: - Actions

    @objc func refreshNow() { refresh() }

    @objc func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
            default:
                try SMAppService.mainApp.register()
            }
        } catch {
            errorMessage = "Login item error: \(error.localizedDescription)"
        }
        rebuildMenu()
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
