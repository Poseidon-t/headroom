import AppKit
import UserNotifications
import ServiceManagement

if CommandLine.arguments.contains("--selftest") { exit(runSelfTest()) }
if CommandLine.arguments.contains("--report") {
    let sampler = Sampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 2)   // a second sample gives the swap rate
    let caches = knownCaches.map { var c = $0; c.size = directorySize(c.path); return c }.filter { $0.size > 0 }
    print(report(sampler.sample(), caches: caches))
    exit(0)
}

/// NSMenuItem that calls a closure.
final class Item: NSMenuItem {
    private var handler: (() -> Void)?
    convenience init(_ title: String, enabled: Bool = true, _ handler: (() -> Void)? = nil) {
        self.init(title: title, action: handler == nil ? nil : #selector(fire), keyEquivalent: "")
        self.handler = handler
        self.target = self
        isEnabled = enabled && handler != nil
    }
    @objc private func fire() { handler?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let sampler = Sampler()
    private let queue = DispatchQueue(label: "unslow.sample")
    private var snap = Snapshot()
    private var caches = knownCaches
    private var lastNotified: [String: Date] = [:]
    private var lastLevel: [String: Level] = [:]

    func applicationDidFinishLaunching(_ note: Notification) {
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading
        render()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        refresh()
        refreshCacheSizes()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
        Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in self?.refreshCacheSizes() }
    }

    // MARK: Sampling

    private func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let s = self.sampler.sample()
            DispatchQueue.main.async {
                self.snap = s
                self.render()
                self.notifyIfNeeded()
            }
        }
    }

    private func refreshCacheSizes() {
        let list = knownCaches
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sized = list.map { var c = $0; c.size = directorySize(c.path); return c }
            DispatchQueue.main.async { self?.caches = sized }
        }
    }

    private func render() {
        let symbol: String
        switch snap.level {
        case .ok: symbol = "gauge.with.dots.needle.33percent"
        case .tight: symbol = "gauge.with.dots.needle.67percent"
        case .critical: symbol = "gauge.with.dots.needle.100percent"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: snap.headline)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.title = snap.badge.isEmpty ? "" : " " + snap.badge
        statusItem.button?.toolTip = snap.headline
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) { build() }

    private func build() {
        let s = snap
        menu.removeAllItems()

        let head = Item(s.headline)
        head.attributedTitle = NSAttributedString(string: s.headline, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        menu.addItem(head)
        menu.addItem(Item("RAM \(bytesLabel(s.ramUsed)) of \(bytesLabel(s.ramTotal))  ·  swap \(bytesLabel(s.swapUsed))"))
        menu.addItem(Item("Disk \(bytesLabel(s.diskFree)) free of \(bytesLabel(s.diskTotal))"))
        menu.addItem(Item("Load " + s.load.map { String(format: "%.1f", $0) }.joined(separator: "  ·  ")
                          + "  on \(ProcessInfo.processInfo.activeProcessorCount) cores"))

        let fix = quickFixPlan()
        menu.addItem(.separator())
        if fix.isEmpty {
            menu.addItem(Item("Quick fix: nothing safe to clean"))
        } else {
            menu.addItem(Item("Quick fix: \(fix.summary)…") { [weak self] in self?.quickFix() })
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Heaviest apps"))
        for g in s.groups.prefix(8) {
            let item = Item("\(g.name)    \(bytesLabel(g.rss))  ·  \(Int(g.cpu))% CPU")
            item.isEnabled = true
            item.submenu = appMenu(g)
            menu.addItem(item)
        }

        if !s.sessions.isEmpty {
            menu.addItem(.separator())
            let total = s.sessions.map(\.rss).reduce(0, +)
            menu.addItem(.sectionHeader(title: "Claude Code sessions: \(s.sessions.count), \(bytesLabel(total)) together"))
            for sess in s.sessions {
                let item = Item(sess.label)
                item.isEnabled = true
                let sub = NSMenu()
                sub.addItem(Item("Close session (its conversation ends)") { [weak self] in
                    self?.confirmStop("Close the Claude session \"\(sess.title)\"?",
                                      "The session has been open \(ageLabel(sess.age)). Its tab in VS Code will disconnect and the conversation stops.",
                                      trees: [sess.tree])
                })
                item.submenu = sub
                menu.addItem(item)
            }
            let idle = s.sessions.filter(\.idle)
            if idle.count > 1 {
                menu.addItem(Item("Close \(idle.count) idle sessions…") { [weak self] in
                    self?.confirmStop("Close \(idle.count) idle Claude sessions?",
                                      idle.map(\.label).joined(separator: "\n"), trees: idle.map(\.tree))
                })
            }
        }

        if !s.servers.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Dev servers"))
            for srv in s.servers {
                menu.addItem(Item(srv.label + "   Stop") { [weak self] in
                    self?.confirmStop("Stop \(srv.tool) in \(srv.project)?", srv.label, trees: [srv.tree])
                })
            }
        }

        menu.addItem(.separator())
        let visible = caches.filter { $0.size > 50 << 20 }
        let cacheTotal = visible.map(\.size).reduce(0, +)
        let cacheItem = Item("Caches: \(bytesLabel(cacheTotal))")
        cacheItem.isEnabled = true
        let sub = NSMenu()
        sub.autoenablesItems = false
        let clearable = visible.filter { !($0.blockedBy.map(isOpen) ?? false) }
        if clearable.count > 1 {
            sub.addItem(Item("Clear all  \(bytesLabel(clearable.map(\.size).reduce(0, +)))…") { [weak self] in
                self?.confirmClear(clearable)
            })
            sub.addItem(.separator())
        }
        for c in visible {
            if let blocker = c.blockedBy, isOpen(blocker) {
                sub.addItem(Item("\(c.name)  \(bytesLabel(c.size))  (quit \(c.name) first)"))
            } else {
                sub.addItem(Item("\(c.name)  \(bytesLabel(c.size))") { [weak self] in self?.confirmClear([c]) })
            }
        }
        if visible.isEmpty { sub.addItem(Item("No caches over 50 MB")) }
        cacheItem.submenu = sub
        menu.addItem(cacheItem)

        menu.addItem(.separator())
        menu.addItem(Item("Open Activity Monitor") {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                               configuration: .init())
        })
        let login = Item("Open at login") { [weak self] in self?.toggleLogin() }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(Item("Quit Unslow") { NSApp.terminate(nil) })
    }

    private func appMenu(_ g: AppGroup) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(Item("\(g.pids.count) process\(g.pids.count == 1 ? "" : "es")"))
        if let app = runningApp(named: g.name) {
            sub.addItem(Item("Quit \(g.name)") { app.terminate() })
            sub.addItem(Item("Force quit \(g.name)…") { [weak self] in
                if self?.confirm("Force quit \(g.name)?", "Unsaved work in \(g.name) will be lost.", "Force Quit") == true {
                    app.forceTerminate()
                }
            })
        } else if g.name != "WindowServer", g.name != "kernel_task" {
            sub.addItem(Item("Stop these processes…") { [weak self] in
                self?.confirmStop("Stop \(g.pids.count) \(g.name) processes?", "They get a normal stop signal first.", trees: [g.pids])
            })
        }
        return sub
    }

    // MARK: Actions

    private struct Plan {
        var caches: [Cache] = []
        var servers: [Server] = []
        var isEmpty: Bool { caches.isEmpty && servers.isEmpty }
        var summary: String {
            var parts: [String] = []
            if !caches.isEmpty { parts.append("clear \(bytesLabel(caches.map(\.size).reduce(0, +))) of caches") }
            if !servers.isEmpty { parts.append("stop \(servers.count) idle dev server\(servers.count == 1 ? "" : "s")") }
            return parts.joined(separator: ", ")
        }
    }

    /// Only things that come back on their own: caches rebuild, dev servers restart with npm.
    private func quickFixPlan() -> Plan {
        Plan(caches: caches.filter { $0.size > 50 << 20 && !($0.blockedBy.map(isOpen) ?? false) },
             servers: snap.servers.filter(\.idle))
    }

    private func quickFix() {
        let plan = quickFixPlan()
        var detail = plan.caches.map { "Clear \($0.name) cache, \(bytesLabel($0.size))" }
        detail += plan.servers.map { "Stop \($0.label)" }
        guard confirm("Quick fix: \(plan.summary)?", detail.joined(separator: "\n"), "Clean Up") else { return }
        plan.servers.forEach { stop($0.tree) }
        clear(plan.caches)
    }

    private func confirmClear(_ list: [Cache]) {
        let total = bytesLabel(list.map(\.size).reduce(0, +))
        let title = list.count == 1 ? "Clear the \(list[0].name) cache?" : "Clear \(list.count) caches, \(total)?"
        let names = list.count == 1 ? "" : list.map { "\($0.name), \(bytesLabel($0.size))" }.joined(separator: "\n") + "\n\n"
        guard confirm(title, names + "Frees \(total). Each app rebuilds its cache the next time it needs it.", "Clear") else { return }
        clear(list)
    }

    private func clear(_ list: [Cache]) {
        guard !list.isEmpty else { refresh(); return }
        let before = snap.diskFree
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            list.forEach { emptyDirectory($0.path) }
            DispatchQueue.main.async {
                self?.refreshCacheSizes()
                self?.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard let self else { return }
                    self.post("Freed \(bytesLabel(max(0, self.snap.diskFree - before))) of disk",
                              "\(bytesLabel(self.snap.diskFree)) is now free.", key: "freed", force: true)
                }
            }
        }
    }

    private func confirmStop(_ title: String, _ detail: String, trees: [[Int32]]) {
        guard confirm(title, detail, "Stop") else { return }
        trees.forEach(stop)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.refresh() }
    }

    private func confirm(_ title: String, _ detail: String, _ button: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            _ = confirm("Could not change the login setting", error.localizedDescription, "OK")
        }
    }

    private func runningApp(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && ($0.bundleURL?.deletingPathExtension().lastPathComponent == name)
        }
    }

    private func isOpen(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: Notifications

    /// Notifies when memory or disk gets worse, and at most once an hour while it stays bad.
    private func notifyIfNeeded() {
        let s = snap
        let checks: [(String, Level, String, String)] = [
            ("memory", s.memoryLevel, s.headline,
             "\(s.sessions.count) Claude sessions and \(s.servers.count) dev servers are open. Click to see what uses the most."),
            ("disk", s.diskLevel, "Disk low: \(bytesLabel(s.diskFree)) free",
             "Caches hold \(bytesLabel(caches.map(\.size).reduce(0, +))). Click to clear them."),
        ]
        for (key, level, title, body) in checks {
            let worse = level > (lastLevel[key] ?? .ok)
            lastLevel[key] = level
            if level > .ok, worse || Date().timeIntervalSince(lastNotified[key] ?? .distantPast) > 3600 {
                post(title, body, key: key)
            }
        }
    }

    private func post(_ title: String, _ body: String, key: String, force: Bool = false) {
        if !force, Date().timeIntervalSince(lastNotified[key] ?? .distantPast) < 600 { return }
        lastNotified[key] = Date()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        DispatchQueue.main.async { self.statusItem.button?.performClick(nil) }
        done()
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner])
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
