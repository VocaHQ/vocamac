import Darwin
import XCTest

@testable import VocaMac

final class ProcessMonitorTests: XCTestCase {
    func testRefreshDoesNotLeakCurrentThreadSendRights() throws {
        let thread = pthread_mach_thread_np(pthread_self())
        let monitor = ProcessMonitor(useTimer: false)
        let before = try sendRightReferences(for: thread)
        for _ in 0..<20 { monitor.refresh() }
        let after = try sendRightReferences(for: thread)
        XCTAssertEqual(after, before)
    }

    private func sendRightReferences(for port: mach_port_t) throws -> mach_port_urefs_t {
        var references: mach_port_urefs_t = 0
        let result = mach_port_get_refs(
            mach_task_self_, port, mach_port_right_t(MACH_PORT_RIGHT_SEND), &references
        )
        guard result == KERN_SUCCESS else {
            throw NSError(domain: NSMachErrorDomain, code: Int(result))
        }
        return references
    }
}
