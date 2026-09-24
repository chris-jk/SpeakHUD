// Test runner. No XCTest: stock Command Line Tools don't ship it, and the app
// builds with bare swiftc. Build and run with tests/run.sh.
import Foundation

final class Suite {
    let name: String
    let body: (Suite) -> Void
    private(set) var failures: [String] = []
    private(set) var checks = 0
    init(_ name: String, _ body: @escaping (Suite) -> Void) { self.name = name; self.body = body }

    func expect(_ ok: @autoclosure () -> Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        checks += 1
        if !ok() { failures.append("\(file):\(line): \(what)") }
    }
    func expectEqual<T: Equatable>(_ a: T, _ b: T, _ what: String, file: StaticString = #file, line: UInt = #line) {
        expect(a == b, "\(what) — got \(a), expected \(b)", file: file, line: line)
    }
}

let harnessSuite = Suite("Harness") { t in
    t.expect(parseHotkey("ctrl+opt+s") != nil, "parseHotkey accepts the default combo")
    t.expect(parseHotkey("s") == nil, "parseHotkey rejects a combo with no modifier")
}

// One line per suite; each lives in its own file.
let suites = [harnessSuite, playbackSuite, spoolSuite, claudeHookSuite]

var failed = 0, total = 0
for s in suites {
    s.body(s)
    total += s.checks
    for f in s.failures { print("FAIL [\(s.name)] \(f)") }
    failed += s.failures.count
    print("\(s.failures.isEmpty ? "ok  " : "FAIL") \(s.name): \(s.checks) checks")
}
print("\(total - failed)/\(total) checks passed")
exit(failed == 0 ? 0 : 1)
