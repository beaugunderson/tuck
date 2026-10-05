import Darwin
import Foundation

// killwatch <seconds> <log file> [process name]
//
// Polls the process table and, the first time it sees a process with the given
// name (default "killall"), appends that process's arguments and its whole
// parent chain to the log. Run from a LaunchAgent at login, it answers "what
// kills cfprefsd during login": launchd records the signal's sender as
// `killall[pid]` and nothing about who started it.
//
// Build: swiftc -O -o build/killwatch Tools/killwatch.swift

let stride = MemoryLayout<kinfo_proc>.stride

func processes() -> [kinfo_proc] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
    var list = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
    size = list.count * stride
    guard sysctl(&mib, 3, &list, &size, nil, 0) == 0 else { return [] }
    return Array(list.prefix(size / stride))
}

func name(_ process: kinfo_proc) -> String {
    var command = process.kp_proc.p_comm
    return withUnsafeBytes(of: &command) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

func info(_ pid: pid_t) -> kinfo_proc? {
    var process = kinfo_proc()
    var size = stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &process, &size, nil, 0) == 0, size == stride else { return nil }
    return process
}

func path(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : "?"
}

/// The argument vector, readable for this user's processes and for none other without root.
func arguments(_ pid: pid_t) -> String {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return "(arguments unreadable)" }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return "(arguments unreadable)" }
    let count = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
    // Layout: argc, the executable path, NUL padding, then argc NUL-terminated strings.
    var index = 4
    while index < size, buffer[index] != 0 { index += 1 }
    while index < size, buffer[index] == 0 { index += 1 }
    var result: [String] = []
    while result.count < count, index < size {
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        result.append(String(decoding: buffer[start..<index], as: UTF8.self))
        index += 1
    }
    return result.joined(separator: " ")
}

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 180 : 180
let logPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/dev/stdout"
let target = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "killall"

guard let log = FileHandle(forWritingAtPath: logPath) ?? {
    FileManager.default.createFile(atPath: logPath, contents: nil)
    return FileHandle(forWritingAtPath: logPath)
}() else { fatalError("cannot open \(logPath)") }
log.seekToEndOfFile()

let stamp = ISO8601DateFormatter()
stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
stamp.timeZone = .current
func write(_ line: String) { log.write(Data((line + "\n").utf8)) }

write("\(stamp.string(from: Date())) watching for \"\(target)\" for \(Int(seconds))s (pid \(getpid()))")
var seen = Set<pid_t>()
let deadline = Date().addingTimeInterval(seconds)
while Date() < deadline {
    for process in processes() where name(process) == target && !seen.contains(process.kp_proc.p_pid) {
        seen.insert(process.kp_proc.p_pid)
        write("\(stamp.string(from: Date())) FOUND \(target)")
        var pid = process.kp_proc.p_pid
        var depth = 0
        while pid > 0, depth < 12, let current = info(pid) {
            write("  \(String(repeating: "  ", count: depth))pid \(pid) uid \(current.kp_eproc.e_ucred.cr_uid) \(path(pid)) :: \(arguments(pid))")
            pid = current.kp_eproc.e_ppid
            depth += 1
        }
    }
    usleep(4000)
}
write("\(stamp.string(from: Date())) done, \(seen.count) seen")
