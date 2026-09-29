import Foundation
import Darwin

// MARK: - Parsers

/// Parses ps time fields: "[[dd-]hh:]mm:ss[.ff]".
func parseDuration(_ s: String) -> Double {
    var days = 0.0
    var rest = Substring(s.trimmingCharacters(in: .whitespaces))
    if let dash = rest.firstIndex(of: "-") {
        guard let d = Double(rest[..<dash]) else { return 0 }
        days = d
        rest = rest[rest.index(after: dash)...]
    }
    let parts = rest.split(separator: ":").map { Double($0) }
    guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return 0 }
    return days * 86400 + parts.reduce(0.0) { $0 * 60 + $1! }
}

/// Groups an executable path under the app a person would recognise.
func appName(for path: String) -> String {
    if path.contains("anthropic.claude-code") || path.hasSuffix("/.local/bin/claude") { return "Claude Code" }
    if let r = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app") : nil) {
        return String(path[..<r.lowerBound].split(separator: "/").last ?? "")
    }
    return (path as NSString).lastPathComponent
}

struct PSRow {
    let pid: Int32, ppid: Int32
    let rss: UInt64          // bytes
    let cpuPercent: Double   // ps %cpu, a decayed recent average
    let cpuTime: Double      // cumulative seconds
    let age: Double          // seconds since start
    let path: String
}

/// Parses `ps -axww -o pid=,ppid=,rss=,%cpu=,time=,etime=,comm=`.
func parsePS(_ text: String) -> [PSRow] {
    text.split(separator: "\n").compactMap { line in
        let f = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
        guard f.count == 7, let pid = Int32(f[0]), let ppid = Int32(f[1]),
              let rss = UInt64(f[2]), let cpu = Double(f[3]) else { return nil }
        return PSRow(pid: pid, ppid: ppid, rss: rss * 1024, cpuPercent: cpu,
                     cpuTime: parseDuration(String(f[4])), age: parseDuration(String(f[5])),
                     path: f[6].trimmingCharacters(in: .whitespaces))
    }
}

/// Parses `lsof -nP -iTCP -sTCP:LISTEN -Fpn` into listening ports per pid.
func parseListeners(_ text: String) -> [Int32: [Int]] {
    var out: [Int32: [Int]] = [:]
    var pid: Int32 = 0
    for line in text.split(separator: "\n") {
        if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
        else if line.hasPrefix("n"), let colon = line.lastIndex(of: ":"),
                let port = Int(line[line.index(after: colon)...]), pid > 0 {
            if !(out[pid] ?? []).contains(port) { out[pid, default: []].append(port) }
        }
    }
    return out
}

/// Parses `lsof -a -d cwd -p … -Fpn` into a working directory per pid.
func parseCwd(_ text: String) -> [Int32: String] {
    var out: [Int32: String] = [:]
    var pid: Int32 = 0
    for line in text.split(separator: "\n") {
        if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
        else if line.hasPrefix("n"), pid > 0 { out[pid] = String(line.dropFirst()) }
    }
    return out
}

private func jsonLines(_ text: String) -> [[String: Any]] {
    text.split(separator: "\n").compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
    }
}

/// A title you gave the conversation wins over the latest one Claude generated.
func conversationTitle(_ transcript: String) -> String? {
    var custom: String?, ai: String?
    for e in jsonLines(transcript) {
        if let t = e["customTitle"] as? String, !t.isEmpty { custom = t }
        if let t = e["aiTitle"] as? String, !t.isEmpty { ai = t }
    }
    return custom ?? ai
}

/// The first thing typed into the conversation, skipping IDE context blocks.
func firstPrompt(_ transcript: String) -> String? {
    for e in jsonLines(transcript) where e["type"] as? String == "user" {
        let content = (e["message"] as? [String: Any])?["content"]
        let text = content as? String
            ?? (content as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
        if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<") { return t }
    }
    return nil
}

/// What Claude Code records about the session in a process: ~/.claude/sessions/<pid>.json
/// points at the transcript in ~/.claude/projects/*/<sessionId>.jsonl.
struct SessionMeta { var status: String?; var name: String?; var empty = true }

final class SessionReader {
    private var cache: [String: (size: UInt64, name: String?)] = [:]
    private let root = "\(NSHomeDirectory())/.claude"

    func meta(pid: Int32) -> SessionMeta? {
        guard let data = FileManager.default.contents(atPath: "\(root)/sessions/\(pid).json"),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = d["sessionId"] as? String else { return nil }
        var m = SessionMeta(status: d["status"] as? String)
        let projects = "\(root)/projects"
        guard let dir = ((try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? [])
                .first(where: { FileManager.default.fileExists(atPath: "\(projects)/\($0)/\(id).jsonl") }) else { return m }
        let path = "\(projects)/\(dir)/\(id).jsonl"
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64) ?? 0
        m.empty = false
        if let hit = cache[id], hit.size == size { m.name = hit.name; return m }
        // Titles are appended as the conversation grows, so read the tail; the first prompt is near the head.
        guard let h = FileHandle(forReadingAtPath: path) else { return m }
        defer { try? h.close() }
        let head = String(decoding: h.readData(ofLength: 256 << 10), as: UTF8.self)
        try? h.seek(toOffset: size > 512 << 10 ? size - (512 << 10) : 0)
        let tail = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        m.name = conversationTitle(tail) ?? conversationTitle(head) ?? firstPrompt(head).map { String($0.prefix(50)) }
        cache[id] = (size, m.name)
        return m
    }
}

func ageLabel(_ seconds: Double) -> String {
    let s = Int(seconds)
    if s >= 86400 { return "\(s / 86400)d \(s % 86400 / 3600)h" }
    if s >= 3600 { return "\(s / 3600)h" }
    return "\(max(1, s / 60))m"
}

func bytesLabel<T: BinaryInteger>(_ n: T) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .memory)
}

/// Memory a process accounts for, including compressed and swapped pages, as Activity Monitor
/// reports it. Returns nil for processes owned by other users.
func footprint(_ pid: Int32) -> UInt64? {
    var info = rusage_info_v2()
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
        }
    }
    return ok == 0 ? info.ri_phys_footprint : nil
}

func sh(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Snapshot

enum Level: Int, Comparable {
    case ok, tight, critical
    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
}

struct AppGroup { let name: String; let pids: [Int32]; let rss: UInt64; let cpu: Double }

struct Session {
    let pid: Int32, tree: [Int32]
    let project: String, age: Double, rss: UInt64, cpu: Double
    var meta: SessionMeta? = nil
    /// Claude Code's own status when it reports one, otherwise under 2% of a core for 3 minutes.
    var idle: Bool { meta?.status.map { $0 == "idle" } ?? (cpu < 0.02) }
    var empty: Bool { meta?.empty ?? false }
    var title: String {
        let name = meta?.name ?? (empty ? "Empty session" : "Untitled session")
        return project == "~" || project == "?" ? name : "\(name) (\(project))"
    }
    var label: String { "\(title) · \(ageLabel(age)) · \(idle ? "idle" : "working") · \(bytesLabel(rss))" }
}

struct Server {
    let pid: Int32, tree: [Int32], ports: [Int]
    let project: String, tool: String, age: Double, cpu: Double
    var idle: Bool { cpu < 0.02 && age > 3600 }
    var label: String {
        let p = ports.sorted().map { ":\($0)" }.joined(separator: " ")
        return "\(p) \(project) · \(tool) · \(ageLabel(age))\(idle ? " · idle" : "")"
    }
}

struct Cache {
    let name: String, path: String
    let blockedBy: String?   // bundle id of an app that must be closed first
    var size: UInt64 = 0
}

struct Snapshot {
    var ramTotal: UInt64 = 0, ramUsed: UInt64 = 0
    var swapUsed: UInt64 = 0, swapTotal: UInt64 = 0
    var swapPagesPerSec: Double = 0
    var pressure = 1              // 1 normal, 2 warning, 4 critical
    var diskFree: Int64 = 0, diskTotal: Int64 = 0
    var load: [Double] = [0, 0, 0]
    var groups: [AppGroup] = []
    var sessions: [Session] = []
    var servers: [Server] = []

    var swapping: Bool { swapPagesPerSec > 100 }
    var memoryLevel: Level {
        if pressure >= 4 { return .critical }
        if pressure >= 2 || swapping || swapUsed > ramTotal { return .tight }
        return .ok
    }
    var diskLevel: Level {
        let gb: Int64 = 1 << 30
        if diskFree < 5 * gb { return .critical }
        if diskFree < 15 * gb { return .tight }
        return .ok
    }
    var level: Level { max(memoryLevel, diskLevel) }

    var headline: String {
        if diskLevel > memoryLevel { return "Disk nearly full: \(bytesLabel(diskFree)) free" }
        switch memoryLevel {
        case .ok: return diskLevel == .ok ? "All clear" : "Disk low: \(bytesLabel(diskFree)) free"
        case .tight, .critical:
            return swapping ? "Memory tight: swapping to disk now" : "Memory tight: \(bytesLabel(swapUsed)) swapped"
        }
    }
    /// Short text beside the menu bar icon; empty when nothing needs attention.
    var badge: String {
        if level == .ok { return "" }
        if diskLevel >= memoryLevel { return "\(diskFree / (1 << 30)) GB" }
        return "Swap \(String(format: "%.0f", Double(swapUsed) / Double(1 << 30))) GB"
    }
}

// MARK: - Sampler

final class Sampler {
    private var cpuHistory: [Int32: [(t: Double, cpu: Double)]] = [:]
    private var lastSwap: (t: Double, pages: UInt64)?
    private let sessionReader = SessionReader()
    private let serverExes: Set<String> = ["node", "bun", "deno", "ruby", "php", "Python", "python", "python3"]

    func sample() -> Snapshot {
        var s = Snapshot()
        let now = Date().timeIntervalSince1970

        s.ramTotal = sysctlU64("hw.memsize")
        var xs = xsw_usage()
        var len = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &xs, &len, nil, 0)
        s.swapUsed = xs.xsu_used
        s.swapTotal = xs.xsu_total
        s.pressure = Int(sysctlU64("kern.memorystatus_vm_pressure_level", width: 4))

        if let vm = vmStats() {
            s.ramUsed = vm.used
            if let last = lastSwap, now > last.t {
                s.swapPagesPerSec = Double(vm.swapPages &- last.pages) / (now - last.t)
            }
            lastSwap = (now, vm.swapPages)
        }

        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]) {
            s.diskFree = Int64(v.volumeAvailableCapacity ?? 0)
            s.diskTotal = Int64(v.volumeTotalCapacity ?? 0)
        }
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        s.load = load

        let rows = parsePS(sh("/bin/ps", ["-axww", "-o", "pid=,ppid=,rss=,%cpu=,time=,etime=,comm="]))
            .map { r in footprint(r.pid).map { PSRow(pid: r.pid, ppid: r.ppid, rss: $0, cpuPercent: r.cpuPercent,
                                                        cpuTime: r.cpuTime, age: r.age, path: r.path) } ?? r }
        let me = getpid()
        var byPid: [Int32: PSRow] = [:]
        var children: [Int32: [Int32]] = [:]
        for r in rows {
            byPid[r.pid] = r
            children[r.ppid, default: []].append(r.pid)
            cpuHistory[r.pid, default: []].append((now, r.cpuTime))
            cpuHistory[r.pid]!.removeAll { now - $0.t > 180 }
        }
        cpuHistory = cpuHistory.filter { byPid[$0.key] != nil }

        // Fraction of one core used recently: measured over up to 3 minutes of samples.
        func recentCPU(_ pid: Int32) -> Double {
            if let h = cpuHistory[pid], let first = h.first, let last = h.last, last.t - first.t >= 30 {
                return (last.cpu - first.cpu) / (last.t - first.t)
            }
            return (byPid[pid]?.cpuPercent ?? 0) / 100
        }
        func tree(_ pid: Int32) -> [Int32] {
            [pid] + (children[pid] ?? []).flatMap(tree)
        }

        var groups: [String: (pids: [Int32], rss: UInt64, cpu: Double)] = [:]
        for r in rows where r.pid != me {
            let name = appName(for: r.path)
            groups[name, default: ([], 0, 0)].pids.append(r.pid)
            groups[name]!.rss += r.rss
            groups[name]!.cpu += r.cpuPercent
        }
        s.groups = groups.map { AppGroup(name: $0.key, pids: $0.value.pids, rss: $0.value.rss, cpu: $0.value.cpu) }
            .sorted { $0.rss > $1.rss }

        let sessionPids = rows.filter {
            appName(for: $0.path) == "Claude Code" && byPid[$0.ppid].map({ appName(for: $0.path) != "Claude Code" }) ?? true
        }.map(\.pid)
        let listeners = parseListeners(sh("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"]))
        let serverPids = listeners.keys.filter { pid in
            guard let r = byPid[pid], !r.path.contains(".app/") else { return false }
            // Skip helpers whose parent is already a listed server (vite's esbuild and the like).
            if let parent = byPid[r.ppid], listeners[parent.pid] != nil, serverExes.contains(appName(for: parent.path)) { return false }
            return serverExes.contains(appName(for: r.path))
        }
        let wanted = sessionPids + serverPids
        let cwd = wanted.isEmpty ? [:] : parseCwd(sh("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", wanted.map(String.init).joined(separator: ","), "-Fpn"]))
        let args = argsFor(wanted)

        func project(_ pid: Int32) -> String {
            guard let dir = cwd[pid] else { return "?" }
            return dir == NSHomeDirectory() ? "~" : (dir as NSString).lastPathComponent
        }
        s.sessions = sessionPids.compactMap { pid in
            guard let r = byPid[pid] else { return nil }
            if (args[pid] ?? "").contains("--chrome-native-host") { return nil }
            let t = tree(pid)
            return Session(pid: pid, tree: t, project: project(pid), age: r.age,
                           rss: t.compactMap { byPid[$0]?.rss }.reduce(0, +),
                           cpu: t.map(recentCPU).reduce(0, +), meta: sessionReader.meta(pid: pid))
        }.sorted { $0.age > $1.age }
        s.servers = serverPids.compactMap { pid in
            guard let r = byPid[pid] else { return nil }
            let a = args[pid] ?? ""
            let tool = a.contains("vite") ? "vite" : a.contains("next") ? "next" :
                (a.split(separator: " ").dropFirst().first { !$0.hasPrefix("-") }.map { ($0 as NSString).lastPathComponent } ?? appName(for: r.path))
            let t = tree(pid)
            return Server(pid: pid, tree: t, ports: listeners[pid] ?? [], project: project(pid), tool: tool,
                          age: r.age, cpu: t.map(recentCPU).reduce(0, +))
        }.sorted { $0.age > $1.age }
        return s
    }

    private func argsFor(_ pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        var out: [Int32: String] = [:]
        for line in sh("/bin/ps", ["-ww", "-o", "pid=,args=", "-p", pids.map(String.init).joined(separator: ",")]).split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if f.count == 2, let pid = Int32(f[0]) { out[pid] = String(f[1]) }
        }
        return out
    }

    private func sysctlU64(_ name: String, width: Int = 8) -> UInt64 {
        var v: UInt64 = 0
        var size = width
        sysctlbyname(name, &v, &size, nil, 0)
        return v
    }

    private func vmStats() -> (used: UInt64, swapPages: UInt64)? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var page: vm_size_t = 0
        host_page_size(mach_host_self(), &page)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * UInt64(page)
        return (used, stats.swapins + stats.swapouts)
    }
}

// MARK: - Caches

let home = NSHomeDirectory()
let knownCaches: [Cache] = [
    Cache(name: "Codex", path: "\(home)/Library/Caches/com.openai.codex", blockedBy: nil),
    Cache(name: "Brave", path: "\(home)/Library/Caches/BraveSoftware", blockedBy: "com.brave.Browser"),
    Cache(name: "Chrome", path: "\(home)/Library/Caches/Google/Chrome", blockedBy: "com.google.Chrome"),
    Cache(name: "VS Code update downloads", path: "\(home)/Library/Caches/com.microsoft.VSCode.ShipIt", blockedBy: nil),
    Cache(name: "Pen update downloads", path: "\(home)/Library/Caches/pen-updater", blockedBy: nil),
    Cache(name: "Playwright MCP profiles", path: "\(home)/Library/Caches/ms-playwright-mcp", blockedBy: nil),
    Cache(name: "Electron downloads", path: "\(home)/Library/Caches/electron", blockedBy: nil),
    Cache(name: "node-gyp headers", path: "\(home)/Library/Caches/node-gyp", blockedBy: nil),
    Cache(name: "npm", path: "\(home)/.npm/_cacache", blockedBy: nil),
    Cache(name: "pip", path: "\(home)/Library/Caches/pip", blockedBy: nil),
    Cache(name: "Homebrew", path: "\(home)/Library/Caches/Homebrew", blockedBy: nil),
    Cache(name: "Yarn", path: "\(home)/Library/Caches/Yarn", blockedBy: nil),
]

func directorySize(_ path: String) -> UInt64 {
    guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path),
                                                 includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                                 options: [], errorHandler: { _, _ in true }) else { return 0 }
    var total: UInt64 = 0
    for case let url as URL in e {
        total += UInt64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    }
    return total
}

/// Deletes what is inside the folder and keeps the folder itself.
func emptyDirectory(_ path: String) {
    let fm = FileManager.default
    for item in (try? fm.contentsOfDirectory(atPath: path)) ?? [] {
        try? fm.removeItem(atPath: (path as NSString).appendingPathComponent(item))
    }
}

/// SIGTERM to a process tree, children first; SIGKILL for anything left after 3 seconds.
func stop(_ pids: [Int32]) {
    for pid in pids.reversed() { kill(pid, SIGTERM) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}

func report(_ s: Snapshot, caches: [Cache]) -> String {
    var lines = [s.headline,
                 "RAM \(bytesLabel(s.ramUsed)) of \(bytesLabel(s.ramTotal)) · pressure level \(s.pressure)",
                 "Swap \(bytesLabel(s.swapUsed)) of \(bytesLabel(s.swapTotal)) · \(Int(s.swapPagesPerSec)) pages/s",
                 "Disk \(bytesLabel(s.diskFree)) free of \(bytesLabel(s.diskTotal))",
                 "Load " + s.load.map { String(format: "%.1f", $0) }.joined(separator: " · "),
                 "", "Heaviest apps"]
    lines += s.groups.prefix(8).map { "  \($0.name) · \(bytesLabel($0.rss)) · \(Int($0.cpu))% CPU" }
    lines += ["", "Claude Code sessions (\(s.sessions.count))"] + s.sessions.map { "  pid \($0.pid) · \($0.label)" }
    lines += ["", "Dev servers (\(s.servers.count))"] + s.servers.map { "  pid \($0.pid) · \($0.label)" }
    lines += ["", "Caches"] + caches.map { "  \($0.name) · \(bytesLabel($0.size))" }
    return lines.joined(separator: "\n")
}
