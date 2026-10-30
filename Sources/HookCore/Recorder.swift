import Foundation
import Darwin

public struct RunMetadata: Sendable {
    public var event = ""
    public var session = ""
    public var turn = ""
    public var tool = ""
    public var directory = ""
    public var bytes: Int = 0
    var values: [SQLValue] { [.text(event),.text(session),.text(turn),.text(tool),.text(directory),.integer(Int64(bytes))] }
    public init(input: Data, totalBytes: Int) {
        bytes = totalBytes
        guard let body = try? JSONSerialization.jsonObject(with: input) as? [String:Any] else { return }
        func validated(_ key: String, pattern: String) -> String {
            guard let value = body[key] as? String, value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex else { return "" }
            return value
        }
        session = validated("session_id", pattern: "^[a-zA-Z0-9_-]{1,100}$")
        turn = validated("turn_id", pattern: "^[a-zA-Z0-9_-]{1,100}$")
        tool = validated("tool_name", pattern: "^[a-zA-Z0-9_./:-]{1,150}$")
        if let name = body["hook_event_name"] as? String,
           ["PreToolUse","PostToolUse","UserPromptSubmit","Stop","SessionStart","SessionEnd"].contains(name) { event = name }
        if let cwd = body["cwd"] as? String, cwd.hasPrefix("/"), cwd.utf8.count < 2048,
           !cwd.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { directory = cwd }
    }
}

public enum ResultClassifier {
    // Exact fixed messages only. Never persist arbitrary output supplied by a hook.
    private static let guardReasons = [
        "禁止 git reset --hard：会丢失工作区修改。", "禁止强制 git clean：会删除未跟踪文件。",
        "禁止强制 Git 推送：包括 --force-with-lease、+refspec 和 --mirror。",
        "禁止强制递归删除（rm -rf）；请明确审查目标并采用范围更小的删除。",
        "禁止删除根目录或整个用户目录。", "禁止 find -delete 批量删除。",
        "禁止 dd 覆盖设备或用户目录文件。", "禁止重定向覆盖磁盘设备。", "禁止擦除或重新分区磁盘。",
        "禁止通过 agent 执行磁盘格式化/分区工具。", "禁止关闭或重启主机。",
        "禁止赋予所有人写权限（777 / a+w / o+w）。", "禁止网络命令直接引用常见凭据文件。",
        "禁止下载与 shell 执行出现在同一命令链；先下载并审查。", "缺少 shell command，无法安全检查。",
        "无法解析命令或 hook 输入。", "hook 输入超过 1 MiB。", "命令嵌套过深，无法安全检查。",
        "无效 hook 事件。", "无效 hook 事件类型。"
    ]
    private static let secretReasons = [
        "检测到疑似密钥或私钥，消息已拒绝。", "检测到中文描述中的疑似密码、密钥或私钥。",
        "检测到 JWK 私钥或对称密钥。", "本地密钥扫描不可用，未放行消息。",
        "本地密钥扫描失败，未放行消息。", "消息检测输入无效，未放行。",
        "消息超过 4 MiB 检测上限，未放行。", "JSON 对象过多，无法完成补充检查。"
    ]
    static let allowed = Set(guardReasons.flatMap { ["Git Security: " + $0, "Security: " + $0] } +
        secretReasons.map { "Secret Guard: " + $0 + " 请移除敏感值，改用环境变量名或 <REDACTED>。" })

    public static func classify(code: Int32, stdout: Data, stderr: Data, signaled: Bool = false, outputTruncated: Bool = false) -> (Outcome, String) {
        if signaled { return (.error, "Hook 被信号中止") }
        if code == 0 && outputTruncated { return (.incomplete,"Hook 输出超过解析上限，无法确认结构化结果") }
        var outcome: Outcome = code == 0 ? .passed : code == 2 ? .blocked : .error
        var reason = ""
        if let json = try? JSONSerialization.jsonObject(with: stdout) as? [String:Any] {
            let specific = json["hookSpecificOutput"] as? [String:Any] ?? [:]
            if ["deny","block"].contains(json["decision"] as? String ?? "") || (json["continue"] as? Bool) == false || specific["permissionDecision"] as? String == "deny" { outcome = .blocked }
            reason = (json["reason"] as? String) ?? (json["stopReason"] as? String) ?? (specific["permissionDecisionReason"] as? String) ?? ""
        }
        if reason.isEmpty && outcome != .passed { reason = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        if !allowed.contains(reason) {
            reason = outcome == .blocked ? "Hook 拒绝了本次操作（详细输出未采集）" : outcome == .error ? "Hook 运行异常（详细输出未采集）" : ""
        }
        return (outcome, reason)
    }
}

// A sig_atomic_t-sized value; handlers do no allocation or Foundation work.
private var receivedSignal: Int32 = 0
private func recordSignal(_ number: Int32) { receivedSignal = number }

public enum Recorder {
    /// Stream all three pipes concurrently with bounded buffers. No input/output is written to disk.
    /// The command is always run exactly once, even when the audit database is unavailable.
    public static func run(command: String, hook: String, database: URL) -> Int32 {
        let store = RunStore(url: database), id = UUID().uuidString
        let start = Date(), clock = DispatchTime.now().uptimeNanoseconds
        let inserted = store.begin(id: id, hook: hook, at: Int64(start.timeIntervalSince1970 * 1000))
        var inputPipe = [Int32](repeating: 0, count: 2)
        var outputPipe = inputPipe, errorPipe = inputPipe
        guard pipe(&inputPipe) == 0 else { return fallback(command) }
        guard pipe(&outputPipe) == 0 else { inputPipe.forEach { close($0) }; return fallback(command) }
        guard pipe(&errorPipe) == 0 else { (inputPipe + outputPipe).forEach { close($0) }; return fallback(command) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO)
        for fd in inputPipe + outputPipe + errorPipe { posix_spawn_file_actions_addclose(&actions, fd) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        var defaults = sigset_t(); sigemptyset(&defaults)
        for number in [SIGPIPE,SIGTERM,SIGINT,SIGHUP] { sigaddset(&defaults, number) }
        var mask = sigset_t(); sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        // Keep the host's process group so its timeout/cancellation can kill the whole hook tree.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var pid: pid_t = 0
        let strings = ["/bin/sh", "-c", command].map { strdup($0) }
        var argv = strings + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) }
        var envp = environment + [nil]
        let launch = argv.withUnsafeMutableBufferPointer { ptr in
            envp.withUnsafeMutableBufferPointer { env in
                posix_spawn(&pid, "/bin/sh", &actions, &attributes, ptr.baseAddress!, env.baseAddress!)
            }
        }
        strings.forEach { free($0) }
        environment.forEach { free($0) }
        posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes)
        close(inputPipe[0]); close(outputPipe[1]); close(errorPipe[1])
        guard launch == 0 else {
            close(inputPipe[1]); close(outputPipe[0]); close(errorPipe[0])
            if inserted { store.finish(id:id,at:Int64(Date().timeIntervalSince1970*1000),duration:0,outcome:.error,code:127,reason:"无法启动 Hook 命令") }
            return 127
        }
        signal(SIGPIPE, SIG_IGN)
        receivedSignal = 0
        for number in [SIGTERM,SIGINT,SIGHUP] { signal(number, recordSignal) }
        _ = fcntl(inputPipe[1], F_SETFL, fcntl(inputPipe[1], F_GETFL) | O_NONBLOCK)
        var pending = Data(), capture = Data(), output = Data(), errors = Data()
        var total = 0, outputBytes = 0, inputEOF = false, childInputOpen = true, outputOpen = true, errorsOpen = true
        var childDone = false, status: Int32 = 0, metadataSaved = false
        var childFinished: Date?
        let originalParent = getppid()
        var forwarded: Int32 = 0
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while !childDone || outputOpen || errorsOpen {
            if receivedSignal != 0 && forwarded != receivedSignal { forwarded = receivedSignal; kill(pid, forwarded) }
            if getppid() != originalParent && !childDone { kill(pid, SIGTERM) }
            if !childDone {
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid { childDone = true; childFinished = .now }
            }
            if childInputOpen && ((inputEOF && pending.isEmpty) || childDone) { close(inputPipe[1]); childInputOpen = false }
            if inserted && !metadataSaved && (inputEOF || childDone) {
                store.updateInput(id: id, metadata: RunMetadata(input:capture,totalBytes:total)); metadataSaved = true
            }
            if childDone && !outputOpen && !errorsOpen { break }
            // A detached background descendant must not keep the wrapper alive indefinitely.
            if let finished = childFinished, Date().timeIntervalSince(finished) > 0.3 { break }
            var polls: [pollfd] = [], tags: [Int] = []
            if !inputEOF && !childDone && pending.count < 65_536 { polls.append(pollfd(fd:0,events:Int16(POLLIN),revents:0)); tags.append(0) }
            if childInputOpen && !pending.isEmpty { polls.append(pollfd(fd:inputPipe[1],events:Int16(POLLOUT),revents:0)); tags.append(1) }
            if outputOpen { polls.append(pollfd(fd:outputPipe[0],events:Int16(POLLIN),revents:0)); tags.append(2) }
            if errorsOpen { polls.append(pollfd(fd:errorPipe[0],events:Int16(POLLIN),revents:0)); tags.append(3) }
            let ready = poll(&polls, nfds_t(polls.count), 25)
            if ready < 0 { if errno == EINTR { continue }; break }
            for (index, entry) in polls.enumerated() where entry.revents != 0 {
                let tag = tags[index]
                if tag == 1 {
                    let written = pending.withUnsafeBytes { Darwin.write(entry.fd, $0.baseAddress, $0.count) }
                    if written > 0 { pending.removeFirst(written) }
                    else if written < 0 && errno != EAGAIN && errno != EINTR { close(inputPipe[1]); childInputOpen = false; pending.removeAll() }
                } else {
                    let count = Darwin.read(entry.fd, &bytes, bytes.count)
                    if count > 0 {
                        let chunk = Data(bytes[0..<count])
                        if tag == 0 {
                            total += count
                            if capture.count <= 4*1024*1024 { capture.append(chunk.prefix(max(0,4*1024*1024+1-capture.count))) }
                            if childInputOpen { pending.append(chunk) }
                        } else {
                            forward(chunk, to:tag == 2 ? STDOUT_FILENO : STDERR_FILENO)
                            if tag == 2 { outputBytes += count; output.append(chunk.prefix(max(0,8192-output.count))) }
                            else { errors.append(chunk.prefix(max(0,8192-errors.count))) }
                        }
                    } else if count == 0 || (count < 0 && errno != EINTR && errno != EAGAIN) {
                        switch tag {
                        case 0: inputEOF = true
                        case 2: close(outputPipe[0]); outputOpen = false
                        default: close(errorPipe[0]); errorsOpen = false
                        }
                    }
                }
            }
        }
        if childInputOpen { close(inputPipe[1]) }
        if outputOpen { close(outputPipe[0]) }
        if errorsOpen { close(errorPipe[0]) }
        if !childDone { kill(pid,SIGTERM); while waitpid(pid,&status,0) < 0 && errno == EINTR {} }
        let sig = status & 0x7f
        let signaled = sig != 0 && sig != 0x7f
        let code = signaled ? 128 + sig : (status >> 8) & 0xff
        if inserted {
            if !metadataSaved { store.updateInput(id:id,metadata:RunMetadata(input:capture,totalBytes:total)) }
            let result = ResultClassifier.classify(code:code,stdout:output,stderr:errors,signaled:signaled,outputTruncated:outputBytes > output.count)
            store.finish(id:id,at:Int64(Date().timeIntervalSince1970*1000),duration:Double(DispatchTime.now().uptimeNanoseconds-clock)/1_000_000,outcome:result.0,code:code,reason:result.1)
        }
        if signaled { signal(sig,SIG_DFL); raise(sig) }
        return code
    }
    private static func forward(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset)
                if n > 0 { offset += n }
                else if n < 0 && errno == EINTR { continue }
                else { return }
            }
        }
    }
    private static func fallback(_ command: String) -> Int32 {
        let strings = ["/bin/sh","-c",command].map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var argv = strings + [nil]
        argv.withUnsafeMutableBufferPointer { _ = execv("/bin/sh",$0.baseAddress!) }
        return 127
    }
}
