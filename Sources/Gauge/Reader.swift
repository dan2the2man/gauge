import Foundation
import Darwin

/// Read-only client for the local `codex app-server` (stdio JSON-RPC).
/// One short-lived child per read; the whole process group is torn down afterwards.
/// Only the methods in `allowed` can ever be sent. No auth material is touched here:
/// the app-server uses its own login.
enum AppServer {
    /// Where a `codex` binary may live for the current user. Checked in order; nothing is hardcoded
    /// to a particular machine. `GAUGE_CODEX_PATH` overrides everything.
    static var candidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: [String] = []
        if let o = ProcessInfo.processInfo.environment["GAUGE_CODEX_PATH"], !o.isEmpty { paths.append(o) }
        if let o = UserDefaults.standard.string(forKey: "codexPath"), !o.isEmpty { paths.append(o) }
        for app in ["/Applications", "\(home)/Applications"] {
            paths.append("\(app)/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
            paths.append("\(app)/Codex.app/Contents/Resources/codex")
            paths.append("\(app)/Codex.app/Contents/Resources/codex-cli/bin/codex")
        }
        paths += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                  "\(home)/.local/bin/codex", "\(home)/.npm-global/bin/codex", "\(home)/.bun/bin/codex",
                  "\(home)/.volta/bin/codex"]
        return paths
    }
    static var codexPath: String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    static let allowed: Set<String> = ["initialize", "initialized", "account/rateLimits/read"]

    struct Output { var rateLimits: [String: Any] }
    enum Failure: Error, CustomStringConvertible {
        case missing, spawn(Int32), timeout, closed, rpc(String), blocked(String)
        var description: String {
            switch self {
            case .missing: return "codex not found"
            case .spawn(let e): return "spawn failed (\(e))"
            case .timeout: return "timed out"
            case .closed: return "app-server closed"
            case .rpc(let m): return "app-server error: \(m)"
            case .blocked(let m): return "blocked method \(m)"
            }
        }
    }

    static func readRateLimits(timeout: TimeInterval = 20) -> Result<Output, Failure> {
        guard let codexPath else { return .failure(.missing) }
        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0 else { return .failure(.spawn(errno)) }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var env = ProcessInfo.processInfo.environment
        // npm/bun-installed codex is a node script; give it a PATH that can find node.
        let binDir = (codexPath as NSString).deletingLastPathComponent
        env["PATH"] = "\(binDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let argv = ["/usr/bin/nice", "-n", "10", codexPath, "app-server"]
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, &attr, cArgs, cEnv)
        cArgs.forEach { free($0) }; cEnv.forEach { free($0) }
        posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr)
        close(inPipe[0]); close(outPipe[1])
        let wfd = inPipe[1], rfd = outPipe[0]
        defer { close(rfd); teardown(pid: pid, writeFD: wfd) }
        guard rc == 0 else { return .failure(.spawn(rc)) }

        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)

        func send(_ obj: [String: Any]) -> Failure? {
            guard let m = obj["method"] as? String, allowed.contains(m) else {
                return .blocked(obj["method"] as? String ?? "?")
            }
            guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return .closed }
            d.append(0x0A)
            let ok = d.withUnsafeBytes { p -> Bool in
                var off = 0
                while off < p.count {
                    let n = write(wfd, p.baseAddress! + off, p.count - off)
                    if n <= 0 { return false }
                    off += n
                }
                return true
            }
            return ok ? nil : .closed
        }
        func waitFor(id: Int) -> Result<[String: Any], Failure> {
            while true {
                if let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                       (msg["id"] as? Int) == id {
                        if let err = msg["error"] as? [String: Any] {
                            return .failure(.rpc(err["message"] as? String ?? "unknown"))
                        }
                        return .success(msg["result"] as? [String: Any] ?? [:])
                    }
                    continue
                }
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { return .failure(.timeout) }
                var pfd = pollfd(fd: rfd, events: Int16(POLLIN), revents: 0)
                let pr = poll(&pfd, 1, Int32(min(remaining, 5) * 1000))
                if pr < 0 { if errno == EINTR { continue }; return .failure(.closed) }
                if pr == 0 { continue }
                var chunk = [UInt8](repeating: 0, count: 65536)
                let n = read(rfd, &chunk, chunk.count)
                if n <= 0 { return .failure(.closed) }
                buffer.append(contentsOf: chunk[0..<n])
            }
        }

        if let e = send(["id": 1, "method": "initialize",
                         "params": ["clientInfo": ["name": "gauge", "title": "Gauge", "version": appVersion]]]) {
            return .failure(e)
        }
        if case .failure(let e) = waitFor(id: 1) { return .failure(e) }
        if let e = send(["method": "initialized"]) { return .failure(e) }
        if let e = send(["id": 2, "method": "account/rateLimits/read",
                         "params": ["excludeResetCreditDetails": false]]) { return .failure(e) }
        switch waitFor(id: 2) {
        case .success(let r): return .success(Output(rateLimits: r))
        case .failure(let e): return .failure(e)
        }
    }

    /// Close stdin, SIGTERM the process group, then SIGKILL anything left, and reap.
    private static func teardown(pid: pid_t, writeFD: Int32) {
        close(writeFD)
        guard pid > 0 else { return }
        kill(-pid, SIGTERM)
        var status: Int32 = 0
        var reaped = false
        for _ in 0..<30 {
            if waitpid(pid, &status, WNOHANG) == pid { reaped = true; break }
            usleep(50_000)
        }
        kill(-pid, SIGKILL)               // stragglers in the group (no-op if all gone)
        if !reaped { _ = waitpid(pid, &status, 0) }
    }
}

/// First-run checks. Existence checks only: Gauge never opens auth files.
enum Setup {
    enum Issue: Equatable { case codexMissing, notSignedIn
        var title: String { self == .codexMissing ? "Codex isn't installed" : "Codex isn't signed in" }
        var detail: String {
            switch self {
            case .codexMissing: return "Gauge reads your usage from the Codex app on this Mac. Install the ChatGPT desktop app or the Codex CLI, then choose Refresh."
            case .notSignedIn: return "Open Codex and sign in with your ChatGPT account, then choose Refresh. Gauge only reads your own usage, locally."
            }
        }
    }
    static var codexHome: URL {
        if let h = ProcessInfo.processInfo.environment["CODEX_HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
    /// Called after a failed live read. Missing binary → not installed. An auth error from the
    /// app-server → not signed in, whether or not auth.json exists (it can be present but expired or
    /// logged out). A failed read with no Codex login on disk → not signed in.
    static func diagnose(_ f: AppServer.Failure) -> Issue? {
        if case .missing = f { return .codexMissing }
        if case .rpc(let m) = f, Parse.isAuthError(m) { return .notSignedIn }
        let fm = FileManager.default
        if !fm.fileExists(atPath: codexHome.appendingPathComponent("auth.json").path) {
            if case .rpc = f { return .notSignedIn }
            if !fm.fileExists(atPath: codexHome.path) { return .notSignedIn }
        }
        return nil
    }
}
