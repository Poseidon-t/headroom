import Foundation

// `Unslow --selftest` checks the parsers against output captured from this Mac.
func runSelfTest() -> Int32 {
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
        print((ok ? "ok   " : "FAIL ") + name)
        if !ok { failures += 1 }
    }

    // ps elapsed and cpu time formats
    check("duration mm:ss", parseDuration("06:37") == 397)
    check("duration hh:mm:ss", parseDuration("14:00:33") == 50433)
    check("duration dd-hh:mm:ss", parseDuration("03-21:12:59") == 335579)
    check("duration fractional cpu time", abs(parseDuration("123:45.67") - 7425.67) < 0.001)
    check("duration garbage", parseDuration("abc") == 0)

    // grouping executables into apps
    check("app from nested helper", appName(for: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Renderer).app/Contents/MacOS/Code Helper (Renderer)") == "Visual Studio Code")
    check("claude code binary", appName(for: "/Users/me/.vscode/extensions/anthropic.claude-code-2.1.283-darwin-arm64/resources/native-binary/claude") == "Claude Code")
    check("plain binary", appName(for: "/usr/local/bin/node") == "node")
    check("system daemon", appName(for: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer") == "WindowServer")

    // ps rows
    let ps = """
      715   492  18768   0.0   0:01.23 03-21:12:59 /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper
    32460 32445   3344   0.1   1:02.50    23:36:19 /usr/local/bin/node
    garbage line
    """
    let rows = parsePS(ps)
    check("ps row count", rows.count == 2)
    check("ps path keeps spaces", rows.first?.path == "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper")
    check("ps rss in bytes", rows.first?.rss == 18768 * 1024)
    check("ps cpu time", rows.last.map { abs($0.cpuTime - 62.5) < 0.001 } ?? false)
    check("ps age", rows.last?.age == 84979)

    // lsof -F output
    let lsof = "p32460\nf21\nn*:5173\nf22\nn[::1]:5173\np26957\nf19\nn127.0.0.1:3001\n"
    let ports = parseListeners(lsof)
    check("lsof ports deduplicated", ports[32460] == [5173])
    check("lsof second pid", ports[26957] == [3001])
    let cwd = parseCwd("p7880\nfcwd\nn/Users/me/code/my-app\n")
    check("lsof cwd", cwd[7880] == "/Users/me/code/my-app")

    // labels
    check("age label days", ageLabel(335579) == "3d 21h")
    check("age label hours", ageLabel(50433) == "14h")
    check("age label minutes", ageLabel(397) == "6m")

    // footprint includes swapped memory, so it is at least as large as what ps sees in RAM
    let mine = parsePS(sh("/bin/ps", ["-o", "pid=,ppid=,rss=,%cpu=,time=,etime=,comm=", "-p", "\(getpid())"])).first
    check("footprint readable for own process", footprint(getpid()) != nil)
    check("footprint is plausible", (footprint(getpid()) ?? 0) > 1 << 20 && mine != nil)
    check("footprint nil for root process", footprint(1) == nil)

    // conversation titles from transcript lines
    let transcript = """
    {"type":"user","message":{"role":"user","content":"<ide_selection>x</ide_selection>"}}
    {"type":"user","message":{"role":"user","content":[{"type":"text","text":"free up the system and make it faster"}]}}
    {"type":"ai-title","sessionId":"s","aiTitle":"System performance"}
    {"type":"ai-title","sessionId":"s","aiTitle":"System performance improvement"}
    """
    check("latest ai title wins", conversationTitle(transcript) == "System performance improvement")
    check("custom title beats ai title", conversationTitle(transcript + "\n{\"type\":\"custom-title\",\"customTitle\":\"Unslow\"}") == "Unslow")
    check("first prompt when untitled", firstPrompt(transcript) == "free up the system and make it faster")
    check("no title in empty text", conversationTitle("") == nil)

    print(failures == 0 ? "all passed" : "\(failures) failed")
    return failures == 0 ? 0 : 1
}
