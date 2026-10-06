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

        func remaining(_ sinceWrite: TimeInterval) -> TimeInterval {
            AgentBar.settleRemaining(lastWrite: earlier, now: earlier.addingTimeInterval(sinceWrite), settle: 3)
        }
        check(remaining(0.015) > 2.9, "A look 15ms after a write waits out the rest of the settle")
        check(remaining(3) == 0, "A look a full settle after the write goes ahead")
        check(remaining(40) == 0, "A long-settled write needs no wait")
        check(AgentBar.settleRemaining(lastWrite: nil, now: earlier, settle: 3) == 0, "No write yet needs no wait")

        let bar = CGRect(x: 0, y: 0, width: 3008, height: 30)
        check(AgentBar.isReadable(windowFrames: [bar]), "A bar window with a size can be read")
        check(!AgentBar.isReadable(windowFrames: [.zero]), "The 0 by 0 window under the screen saver cannot be read")
        check(!AgentBar.isReadable(windowFrames: []), "No bar window cannot be read")
        check(AgentBar.isReadable(windowFrames: [.zero, bar]), "One sized bar window is enough")

        check(AgentBar.isStandIn(vendor: 0x756e_6b6e, model: 0x7669_7274), "The display made when no monitor is connected is a stand-in")
        check(!AgentBar.isStandIn(vendor: 0x6b3, model: 0x32f2), "A real monitor is not a stand-in")
        check(!AgentBar.isStandIn(vendor: 0x756e_6b6e, model: 0x32f2), "An unknown vendor alone is not a stand-in")

        let own = Processes.start(of: getpid())
        check(own != nil && abs(own!.timeIntervalSinceNow) < 60, "Reads this process's start time")
        check(Processes.start(of: 0x7fff_fff0) == nil, "A pid that does not exist has no start time")
        let name = ProcessInfo.processInfo.processName
        check(Processes.pids(named: String(name.prefix(16))).contains(getpid()), "Finds this process by executable name")
        check(Processes.pids(named: "no-such-process-name").isEmpty, "An unknown name matches nothing")

        print("AgentBar tests passed (\(checks) checks)")
    }
}
