import Foundation
import XCTest
import VestalCore

/// Replays Fixtures/expr-cases.json: every case there was run through real
/// jq (1.7.1, or 1.8.1 for the few 1.8-only builtins) by
/// scripts/gen-expr-fixtures.py, so the expectations are ground truth.
final class ExprFixtureTests: XCTestCase {
    func testMatchesJQ() throws {
        guard case .array(let cases) = try JQValue.parse(try Fixture.data("expr-cases.json")) else {
            return XCTFail("expr-cases.json is not an array")
        }
        XCTAssertGreaterThan(cases.count, 900)
        var failures = 0
        for c in cases {
            if let problem = check(c) {
                failures += 1
                let line = c.objectValue?["line"].map { $0.jsonText() } ?? "?"
                let expr = c.objectValue?["expr"]?.stringValue ?? "?"
                XCTFail("expr-cases.txt line \(line): \(expr)\n  \(problem)")
            }
            if failures > 50 { return XCTFail("stopping after 50 failures") }
        }
    }

    /// nil when `c` behaves as jq did, else what differs.
    private func check(_ c: JQValue) -> String? {
        guard case .object(let o) = c, case .string(let expr)? = o["expr"] else { return "malformed case" }
        let input = o["input"] ?? .null
        let expected = o["outputs"]?.arrayValue ?? []
        let expectedError = o["error"]?.stringValue
        let kind = o["kind"]?.stringValue
        let loose = o["loose"]?.boolValue ?? false

        var outputs: [JQValue] = []
        var error: JQError?
        do {
            let e = try JQExpression(expr)
            try e.forEach(input) { v in
                outputs.append(v)
                return true
            }
        } catch let e as JQError {
            error = e
        } catch {
            return "non-JQError thrown: \(error)"
        }

        // Compare what jq prints: it shows nan as null and infinities as
        // ±DBL_MAX.
        func same(_ a: [JQValue], _ b: [JQValue]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { $0.jsonText() == $1.jsonText() }
        }
        func show(_ vs: [JQValue]) -> String { "[" + vs.map { $0.jsonText() }.joined(separator: ", ") + "]" }

        guard let expectedError else {
            if let error { return "unexpected error: \(error)" }
            return same(outputs, expected) ? nil : "outputs\n    want: \(show(expected))\n    got:  \(show(outputs))"
        }
        guard let error else {
            return "expected error \"\(expectedError)\", got \(show(outputs))"
        }
        if kind == "compile" {
            return error.kind == .syntax || error.kind == .compile ? nil : "expected a compile error, got \(error)"
        }
        if !loose && error.message != expectedError {
            return "error\n    want: \(expectedError)\n    got:  \(error.message)"
        }
        return same(outputs, expected) ? nil : "outputs before the error\n    want: \(show(expected))\n    got:  \(show(outputs))"
    }
}
