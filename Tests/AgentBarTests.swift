import Foundation

@main
struct AgentBarTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }

        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 1_003)
        check(AgentBar.isDeaf(agentStart: earlier, daemonStart: later), "An agent older than the preferences daemon is deaf")
        check(!AgentBar.isDeaf(agentStart: later, daemonStart: earlier), "An agent started after the daemon hears it")
        check(!AgentBar.isDeaf(agentStart: earlier, daemonStart: earlier), "The same instant is not deaf")
        check(!AgentBar.isDeaf(agentStart: earlier, daemonStart: nil), "No daemon running is not a reason to restart")

        let switches = ["hidden.app": false, "shown.app": true]
        func wrong(onBar: Set<String>, running: Set<String> = ["hidden.app", "shown.app"], known: Set<String> = ["hidden.app", "shown.app"]) -> Set<String> {
            AgentBar.mismatched(switches: switches, onBar: onBar, running: running, known: known)
        }
        check(wrong(onBar: ["shown.app"]).isEmpty, "A bar that matches the switches has nothing wrong")
        check(wrong(onBar: ["shown.app", "hidden.app"]) == ["hidden.app"], "A switched-off app with an icon on the bar is wrong")
        check(wrong(onBar: []) == ["shown.app"], "A switched-on, running app that has had an icon and has none is wrong")
        check(wrong(onBar: [], running: ["hidden.app"]).isEmpty, "A switched-on app that is not running is not expected on the bar")
        check(wrong(onBar: [], known: ["hidden.app"]).isEmpty, "A switched-on app never seen on the bar is not expected there")
        check(wrong(onBar: ["shown.app", "other.app"]).isEmpty, "An app with no switch is ignored")

        let own = Processes.start(of: getpid())
        check(own != nil && abs(own!.timeIntervalSinceNow) < 60, "Reads this process's start time")
        check(Processes.start(of: 0x7fff_fff0) == nil, "A pid that does not exist has no start time")
        let name = ProcessInfo.processInfo.processName
        check(Processes.pids(named: String(name.prefix(16))).contains(getpid()), "Finds this process by executable name")
        check(Processes.pids(named: "no-such-process-name").isEmpty, "An unknown name matches nothing")

        print("AgentBar tests passed (\(checks) checks)")
    }
}
