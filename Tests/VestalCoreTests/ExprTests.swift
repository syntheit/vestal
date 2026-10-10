import Foundation
import XCTest
import VestalCore

/// The expression engine's API, errors, limits and the places where it
/// deliberately differs from jq. jq semantics themselves are covered by
/// ExprFixtureTests against real jq output.
final class ExprTests: XCTestCase {
    private func run(_ expr: String, _ input: JQValue = .null) throws -> [JQValue] {
        try JQExpression(expr).run(input: input)
    }

    private func one(_ expr: String, _ input: JQValue = .null) throws -> JQValue? {
        try JQExpression(expr).first(input)
    }

    private func texts(_ expr: String, _ input: JQValue = .null) throws -> [String] {
        try run(expr, input).map { $0.jsonText() }
    }

    private func error(_ expr: String, _ input: JQValue = .null,
                       file: StaticString = #filePath, line: UInt = #line) -> JQError? {
        do {
            _ = try run(expr, input)
            XCTFail("expected an error from \(expr)", file: file, line: line)
            return nil
        } catch let e as JQError {
            return e
        } catch {
            XCTFail("unexpected error type \(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: API

    func testRunReturnsEveryOutputInOrder() throws {
        XCTAssertEqual(try texts(".[] | . * 2", [1, 2, 3]), ["2", "4", "6"])
        XCTAssertEqual(try texts(".a, .b", ["a": 1, "b": "x"]), ["1", "\"x\""])
    }

    func testFirstStopsAtTheFirstOutput() throws {
        // Would hit the step limit if evaluation went on.
        XCTAssertEqual(try one("range(1e9)"), .number(0))
        XCTAssertNil(try one("empty"))
        XCTAssertNil(try one(".[]", []))
    }

    func testForEachCanStopEarly() throws {
        var seen: [JQValue] = []
        try JQExpression("range(10)").forEach(.null) { v in
            seen.append(v)
            return seen.count < 3
        }
        XCTAssertEqual(seen, [0, 1, 2])
    }

    func testCompileOnceEvaluateMany() throws {
        let e = try JQExpression(".temp | round")
        XCTAssertEqual(try e.first(["temp": 21.6]), .number(22))
        XCTAssertEqual(try e.first(["temp": -3.2]), .number(-3))
        XCTAssertEqual(try e.evaluate(["temp": 1.5]), [.number(2)])
    }

    func testContractCompileAndRun() throws {
        let p = try JQExpression.compile("$x + .", variables: ["x"])
        XCTAssertEqual(try p.run(input: 1, variables: ["x": 2], context: JQEvalContext()), [.number(3)])
    }

    func testDeclaredVariables() throws {
        let e = try JQExpression("[$a, $b]", variables: ["a", "b"])
        XCTAssertEqual(try e.first(.null, variables: ["a": 1, "b": "x"]), [1, "x"])
        // A declared variable the caller does not supply is null.
        XCTAssertEqual(try e.first(.null, variables: ["a": 1]), [1, .null])
    }

    func testUndeclaredVariableIsACompileError() {
        XCTAssertThrowsError(try JQExpression("1 as $x | $y")) { error in
            let e = error as? JQError
            XCTAssertEqual(e?.kind, .compile)
            XCTAssertEqual(e?.message, "$y is not defined")
            XCTAssertEqual(e?.column, 11)
        }
    }

    func testFreeVariablesAreLookedUpAtRunTime() throws {
        let e = try JQExpression("$sources.system.cpu + $extra", allowFreeVariables: true)
        XCTAssertEqual(e.references.variableNames, ["sources", "extra"])
        let sources: JQValue = ["system": ["cpu": 40]]
        XCTAssertEqual(try e.first(.null, variables: ["sources": sources, "extra": 2]), .number(42))
        XCTAssertThrowsError(try e.first(.null, variables: ["sources": sources])) { error in
            XCTAssertEqual((error as? JQError)?.message, "$extra is not defined")
            XCTAssertEqual((error as? JQError)?.kind, .runtime)
        }
    }

    func testReferencesListStaticVariablePaths() throws {
        func paths(_ expr: String) throws -> [String] {
            try JQExpression(expr, allowFreeVariables: true).references.variables.map {
                "$\($0.name)" + $0.path.map { "." + $0 }.joined()
            }
        }
        XCTAssertEqual(try paths("$sources.system.cpu.percent"), ["$sources.system.cpu.percent"])
        XCTAssertEqual(try paths(#"$sources["weather"].now"#), ["$sources.weather.now"])
        XCTAssertEqual(try paths("$sources.a?.b"), ["$sources.a.b"])
        // Dynamic keys, iteration and pipes mean "the whole value".
        XCTAssertEqual(try paths("$sources[$k]"), ["$sources", "$k"])
        XCTAssertEqual(try paths("$sources[$k].a"), ["$sources", "$k"])
        XCTAssertEqual(try paths("$sources | .a"), ["$sources"])
        XCTAssertEqual(try paths("$history.cpu[0]"), ["$history.cpu"])
        // Bound variables are internal, not references.
        XCTAssertEqual(try paths(".a as $sources | $sources.b"), [])
        XCTAssertEqual(try paths("[$x, $x.y]"), ["$x", "$x.y"])
    }

    func testReferencesListCallsWithLiteralArguments() throws {
        var functions = JQFunctions()
        functions.registerValue("meta", arity: 1) { _, args in ["name": args[0]] }
        let e = try JQExpression(#"meta("weather").name, (now | todate), def f: length; f"#, functions: functions)
        XCTAssertTrue(e.references.callsNow)
        XCTAssertTrue(e.references.functionNames.isSuperset(of: ["meta/1", "now/0", "todate/0", "length/0"]))
        XCTAssertFalse(e.references.functionNames.contains("f/0"))
        let meta = e.references.calls.first { $0.name == "meta" }
        XCTAssertEqual(meta?.arguments, [.string("weather")])
        XCTAssertFalse(try JQExpression(".a").references.callsNow)
    }

    func testReferencesIncludeDefinedFunctions() throws {
        var functions = JQFunctions()
        try functions.define("def cpu: $sources.system.cpu; def clock: now | strftime(\"%H:%M\");")
        let e = try JQExpression("cpu, clock", functions: functions)
        XCTAssertEqual(e.references.variables.map(\.path), [["system", "cpu"]])
        XCTAssertTrue(e.references.callsNow)
    }

    // MARK: Context

    func testNowComesFromTheContext() throws {
        let context = JQEvalContext(now: Date(timeIntervalSince1970: 1_425_599_507))
        XCTAssertFalse(context.nowWasCalled)
        let e = try JQExpression("now | todate")
        XCTAssertEqual(try e.first(.null, context: context), "2015-03-05T23:51:47Z")
        XCTAssertTrue(context.nowWasCalled)

        let other = JQEvalContext(now: Date(timeIntervalSince1970: 0))
        _ = try JQExpression(".a").first(["a": 1], context: other)
        XCTAssertFalse(other.nowWasCalled)
    }

    func testLocalTimeUsesTheContextTimeZone() throws {
        let tokyo = JQEvalContext(timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertEqual(try JQExpression("0 | localtime | .[3]").first(.null, context: tokyo), .number(9))
        XCTAssertEqual(try JQExpression(#"0 | strflocaltime("%H:%M %z")"#).first(.null, context: tokyo), "09:00 +0900")
        // strftime and mktime are UTC whatever the zone.
        XCTAssertEqual(try JQExpression(#"0 | strftime("%H:%M %Z")"#).first(.null, context: tokyo), "00:00 UTC")
        XCTAssertEqual(try JQExpression("0 | localtime | mktime").first(.null, context: tokyo), .number(32400))
    }

    // MARK: Registered functions

    /// The one vestal-style formatter in these tests: bytes to "1.2G"-ish.
    private static func bytesFunctions() -> JQFunctions {
        var functions = JQFunctions()
        functions.registerValue("bytes", arity: 0) { input, _ in
            guard case .number(let n) = input else {
                throw JQError.runtime("\(input.typeName) cannot be formatted as bytes")
            }
            let units = ["B", "K", "M", "G", "T"]
            var value = n
            var unit = 0
            while value >= 1024 && unit < units.count - 1 {
                value /= 1024
                unit += 1
            }
            return .string(unit == 0 ? "\(Int(value))B" : String(format: "%.1f%@", value, units[unit]))
        }
        return functions
    }

    func testRegisteredValueFunction() throws {
        let e = try JQExpression(".disks[] | \"\\(.name): \\(.used | bytes)\"", functions: Self.bytesFunctions())
        let input: JQValue = ["disks": [["name": "root", "used": 1_288_490_189], ["name": "tmp", "used": 512]]]
        XCTAssertEqual(try e.run(input: input), ["root: 1.2G", "tmp: 512B"])
        // A thrown JQError is an ordinary, catchable jq error.
        let bad = try JQExpression(#"try ("x" | bytes) catch ."#, functions: Self.bytesFunctions())
        XCTAssertEqual(try bad.first(.null), "string cannot be formatted as bytes")
    }

    func testRegisteredFunctionGetsContextAndReturnsAStream() throws {
        var functions = JQFunctions()
        functions.register("repeat_n", arity: 1) { input, args, context in
            let n = Int(args[0].numberValue ?? 0)
            let tag = context.userInfo["tag"] as? String ?? ""
            return Array(repeating: .string(tag + input.textValue), count: n)
        }
        let e = try JQExpression("[.a | repeat_n(2)]", functions: functions)
        XCTAssertEqual(try e.first(["a": "x"], context: JQEvalContext(userInfo: ["tag": "#"])), ["#x", "#x"])
    }

    func testRegisteredArgumentsCombineLikeJQBuiltins() throws {
        var functions = JQFunctions()
        functions.registerValue("pair", arity: 2) { _, args in .array(args) }
        // The last argument varies slowest, as for jq's C builtins (pow).
        let e = try JQExpression("[pair(1, 2; 3, 4)]", functions: functions)
        XCTAssertEqual(try e.first(.null), [[1, 3], [2, 3], [1, 4], [2, 4]])
    }

    func testRegisteredClosureFunction() throws {
        var functions = JQFunctions()
        // uniq_by(f): first of each key, keeping order.
        functions.registerClosure("uniq_by", arity: 1) { input, args, _ in
            var seen: [JQValue] = []
            var out: [JQValue] = []
            for item in input.arrayValue ?? [] {
                let key = try args[0].first(item) ?? .null
                if !seen.contains(key) {
                    seen.append(key)
                    out.append(item)
                }
            }
            return [.array(out)]
        }
        let e = try JQExpression("uniq_by(.k) | map(.v)", functions: functions)
        let input: JQValue = [["k": "b", "v": 1], ["k": "a", "v": 2], ["k": "b", "v": 3]]
        XCTAssertEqual(try e.first(input), [1, 2])
    }

    func testOtherErrorsFromRegisteredFunctionsBecomeRuntimeErrors() throws {
        struct Oops: Error {}
        var functions = JQFunctions()
        functions.registerValue("oops", arity: 0) { _, _ in throw Oops() }
        XCTAssertThrowsError(try JQExpression("oops", functions: functions).first(.null)) { error in
            XCTAssertEqual((error as? JQError)?.kind, .runtime)
            XCTAssertTrue((error as? JQError)?.message.hasPrefix("oops: ") ?? false)
        }
    }

    func testRegisteredFunctionShadowsBuiltin() throws {
        var functions = JQFunctions()
        functions.registerValue("length", arity: 0) { _, _ in 42 }
        XCTAssertEqual(try JQExpression("[1] | length", functions: functions).first(.null), .number(42))
        XCTAssertEqual(try one("[1] | length"), .number(1))
    }

    func testDefinedFunctions() throws {
        var functions = JQFunctions()
        try functions.define("def gib: . / 1073741824;")
        try functions.define("def gib_text: gib | \"\\(.) GiB\"; def clamp($lo; $hi): [., $lo] | max | [., $hi] | min;")
        XCTAssertEqual(try JQExpression("2147483648 | gib_text", functions: functions).first(.null), "2 GiB")
        XCTAssertEqual(try JQExpression("[5, -5, 50] | map(clamp(0; 10))", functions: functions).first(.null), [5, 0, 10])
        // Definitions may not use later ones.
        XCTAssertThrowsError(try functions.define("def a: b; def b: 1;"))
        XCTAssertThrowsError(try functions.define("1 + 1"))
        XCTAssertThrowsError(try functions.define("def broken: ;"))
        XCTAssertTrue(functions.names.contains("gib/0"))
    }

    // MARK: Errors

    func testSyntaxErrorHasPositionAndSnippet() {
        XCTAssertThrowsError(try JQExpression(".a | | .b")) { error in
            guard let e = error as? JQError else { return XCTFail("\(error)") }
            XCTAssertEqual(e.kind, .syntax)
            XCTAssertEqual(e.message, "unexpected '|'")
            XCTAssertEqual(e.line, 1)
            XCTAssertEqual(e.column, 6)
            XCTAssertEqual(e.offset, 5)
            XCTAssertEqual(e.snippet, "  .a | | .b\n       ^")
            XCTAssertEqual(e.description, "syntax error at line 1, column 6: unexpected '|'\n  .a | | .b\n       ^")
        }
    }

    func testErrorOffsetIsInUTF8Bytes() {
        XCTAssertThrowsError(try JQExpression(#""é" | )"#)) { error in
            let e = error as? JQError
            XCTAssertEqual(e?.column, 7)
            XCTAssertEqual(e?.offset, 7)
        }
    }

    func testMultilineErrorPosition() {
        XCTAssertThrowsError(try JQExpression(".a |\n  map(.b\n")) { error in
            let e = error as? JQError
            XCTAssertEqual(e?.line, 3)
            XCTAssertEqual(e?.message, "unexpected end of expression, expecting ';' or ')' in the argument list of map")
        }
    }

    func testCompileErrorsSuggestFixes() {
        func message(_ expr: String) -> String? {
            do { _ = try JQExpression(expr); return nil } catch { return (error as? JQError)?.message }
        }
        XCTAssertEqual(message("lenght"), "lenght/0 is not defined; did you mean length?")
        XCTAssertEqual(message("map"), "map/0 is not defined (defined: map/1)")
        XCTAssertEqual(message("rates"), "rates/0 is not defined; did you mean paths? To read a field, write .rates")
        XCTAssertEqual(message("temperature"), "temperature/0 is not defined; to read a field, write .temperature")
        XCTAssertEqual(message(".foo-bar"), #"bar/0 is not defined; for a key containing '-', write ."foo-bar""#)
        XCTAssertEqual(message("{a: 1 + 2}"),
                       "unexpected '+' in object value; an object value must be a term or a pipe of terms, so wrap it in parentheses, e.g. {key: (.a + .b)}")
        XCTAssertEqual(message("1 == 1 == 1"), "'==' cannot follow '==' without parentheses (these operators do not chain)")
        XCTAssertEqual(message(""), "empty expression (use . for the input itself)")
        XCTAssertEqual(message("@nope"),
                       "@nope is not a valid format (known: @text, @json, @html, @uri, @csv, @tsv, @sh, @base64, @base64d, @base32, @base32d)")
    }

    func testIOBuiltinsAreUnavailable() {
        for expr in ["input", "inputs", "env", "$ENV", "halt", "input_line_number"] {
            XCTAssertThrowsError(try JQExpression(expr), expr) { error in
                XCTAssertEqual((error as? JQError)?.kind, .compile)
                XCTAssertTrue((error as? JQError)?.message.contains("not available") ?? false, expr)
            }
        }
    }

    func testRuntimeErrorsCarryJQMessagesAndValues() {
        XCTAssertEqual(error(".a", 5)?.message, #"Cannot index number with string "a""#)
        XCTAssertEqual(error(".[]", 5)?.message, "Cannot iterate over number (5)")
        XCTAssertEqual(error(#"{} + 1"#)?.message, "object ({}) and number (1) cannot be added")
        let raised = error(#"error({"code": 7})"#)
        XCTAssertEqual(raised?.kind, .runtime)
        XCTAssertEqual(raised?.value, ["code": 7])
        XCTAssertEqual(raised?.message, #"{"code":7} (not a string)"#)
        XCTAssertEqual(raised?.description, #"error: {"code":7} (not a string)"#)
    }

    // MARK: Limits

    func testStepLimitStopsRunawayRanges() {
        let e = error("[range(1e9)] | length")
        XCTAssertEqual(e?.kind, .limit)
        XCTAssertTrue(e?.message.contains("steps") ?? false)
    }

    func testLimitErrorsCannotBeCaught() {
        XCTAssertEqual(error(#"try ([range(1e9)] | length) catch "caught""#)?.kind, .limit)
        XCTAssertEqual(error(#"[range(1e9)] | length? // 0"#)?.kind, .limit)
    }

    func testStepLimitIsConfigurable() throws {
        let small = JQLimits(maxSteps: 100)
        XCTAssertThrowsError(try JQExpression("[range(1000)]", limits: small).first(.null)) { error in
            XCTAssertEqual((error as? JQError)?.kind, .limit)
        }
        XCTAssertEqual(try JQExpression("[range(50)] | length", limits: small).first(.null), .number(50))
    }

    func testValueSizeLimit() throws {
        let small = JQLimits(maxValueSize: 100)
        func kind(_ src: String, _ input: JQValue = .null) -> JQError.Kind? {
            do { _ = try JQExpression(src, limits: small).run(input: input); return nil } catch { return (error as? JQError)?.kind }
        }
        XCTAssertEqual(kind(#""ab" * 51"#), .limit)
        XCTAssertEqual(kind(#""ab" * 50 | length"#), nil)
        XCTAssertEqual(kind(#""x" * 60 | . + ."#), .limit)
        XCTAssertEqual(kind(#"[range(101)]"#), .limit)
        XCTAssertEqual(kind(#"[range(100)] | length"#), nil)
        XCTAssertEqual(kind(#"[range(60)] | . + ."#), .limit)
        XCTAssertEqual(kind(#"[range(60)] | add"#), nil)
        XCTAssertEqual(kind(#"[range(5)] | map("abcdefghij") | join(",")"#), nil)
        XCTAssertEqual(kind(#"[range(20)] | map("abcdefghij") | join(",")"#), .limit)
        XCTAssertEqual(kind(#"[range(20)] | map("abcdefghij") | add"#), .limit)
        XCTAssertEqual(kind(#"[range(40)] | map("abc") | tojson"#), .limit)
        XCTAssertEqual(kind(#""x" * 60 | "\(.)\(.)""#), .limit)
        XCTAssertEqual(kind(#""x" * 60 | @base64 | "\(.)""#), nil)
        XCTAssertEqual(kind(#"[range(200)] | implode"#), .limit)
        XCTAssertEqual(kind(#""x" * 100 | explode | length"#), nil)
        // Not catchable.
        XCTAssertEqual(kind(#"try ("ab" * 51) catch 0"#), .limit)
        // Defaults leave ordinary work alone.
        XCTAssertEqual(try JQExpression(#"[range(100000)] | map(tostring) | join(",") | length"#).first(.null), .number(588_889))
        XCTAssertEqual(try JQExpression(#""ab" * 1000000 | length"#).first(.null), .number(2_000_000))
        XCTAssertEqual(JQLimits.default.maxValueSize, 10_000_000)
    }

    func testRegexLimits() throws {
        let small = JQLimits(maxRegexSubject: 10, maxRegexPattern: 8)
        func kind(_ src: String) -> JQError.Kind? {
            do { _ = try JQExpression(src, limits: small).run(input: .null); return nil } catch { return (error as? JQError)?.kind }
        }
        XCTAssertEqual(kind(#""aaaaaaaaaaa" | test("a")"#), .limit)
        XCTAssertEqual(kind(#""aaaaaaaaaa" | test("a")"#), nil)
        XCTAssertEqual(kind(#""aaaa" | test("aaaaaaaaa")"#), .limit)
        XCTAssertEqual(kind(#""aaaaaaaaaaa" | gsub("a"; "b")"#), .limit)
        XCTAssertEqual(kind(#"try ("aaaaaaaaaaa" | test("a")) catch 0"#), .limit)
        let hostile = String(repeating: "a", count: 1_000_001)
        XCTAssertThrowsError(try JQExpression(#"test("^(a+)+$")"#).run(input: .string(hostile))) { error in
            XCTAssertEqual((error as? JQError)?.kind, .limit)
        }
        XCTAssertEqual(try JQExpression(#"test("^(a+)+$")"#).first(.string("aaaa")), .bool(true))
    }

    func testDeadline() {
        let limits = JQLimits(maxSteps: .max, maxDuration: 0.05)
        let start = Date()
        XCTAssertThrowsError(try JQExpression("[range(1e12)] | length", limits: limits).first(.null)) { error in
            XCTAssertEqual((error as? JQError)?.kind, .limit)
            XCTAssertTrue((error as? JQError)?.message.contains("seconds") ?? false)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testRunawayRecursionFailsCleanly() {
        XCTAssertEqual(error("def f: f; f")?.kind, .limit)
        XCTAssertEqual(error("def f: 1 + f; f")?.kind, .limit)
        XCTAssertEqual(error("[recurse(if . < 1e9 then . + 1 else empty end)] | length", 0)?.kind, .limit)
    }

    func testRecursionOnASmallStackFailsCleanly() {
        // Background threads can have 512 KiB stacks; running out of stack
        // must be an error, not a crash.
        var result: Result<[JQValue], Error>?
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = Result { try JQExpression("def f: if . > 0 then . - 1 | f else . end; 1000000 | f").run(input: .null) }
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
        guard case .failure(let error)? = result else { return XCTFail("expected a failure, got \(String(describing: result))") }
        XCTAssertEqual((error as? JQError)?.kind, .limit)
    }

    func testModerateRecursionWorks() throws {
        XCTAssertEqual(try one("def fac: if . <= 1 then 1 else . * (. - 1 | fac) end; 20 | fac"), .number(2_432_902_008_176_640_000))
        XCTAssertEqual(try one("def fib: if . < 2 then . else (. - 1 | fib) + (. - 2 | fib) end; 18 | fib"), .number(2584))
        XCTAssertEqual(try one("1 | until(. > 50000; . + 1)"), .number(50001))
        XCTAssertEqual(try one("[1 | while(. < 50000; . + 1)] | length"), .number(49999))
        XCTAssertEqual(try one("[range(0; 50000; 2)] | length"), .number(25000))
    }

    func testOutputLimit() {
        let limits = JQLimits(maxOutputs: 10)
        XCTAssertThrowsError(try JQExpression("range(20)", limits: limits).run(input: .null)) { error in
            XCTAssertEqual((error as? JQError)?.kind, .limit)
        }
        XCTAssertEqual(try JQExpression("range(20)", limits: limits).first(.null), .number(0))
    }

    func testValueSizeLimits() {
        XCTAssertEqual(error("reduce range(2000) as $i (null; [.]) | length")?.kind, .limit)
        XCTAssertEqual(error("reduce range(2000) as $i (null; {a: .}) | length")?.kind, .limit)
        XCTAssertEqual(error("reduce range(2000) as $i (null; .a = .) | length")?.kind, .limit)
        XCTAssertEqual(error(#""x" * 1e9 | length"#)?.kind, .limit)
        XCTAssertEqual(error(".[1e9] = 1", [])?.message, "Array index too large")
        XCTAssertEqual(error("[range(2000)] | reduce .[] as $i ([0]; [.] | group_by(.))")?.kind, .limit)
    }

    func testLongPathsAreRefused() {
        XCTAssertEqual(error("setpath([range(10000) | 0]; 1)")?.kind, .limit)
        XCTAssertEqual(error("delpaths([[range(10000) | 0]])")?.kind, .limit)
        XCTAssertEqual(error("path(getpath([range(10000) | 0])) as $p | null | .[0] |= 1 | setpath($p; 1)")?.kind, .limit)
    }

    func testUnusableDurationsMeanNoDeadline() throws {
        for duration in [Double.infinity, .nan, 1e300, -1] {
            let e = try JQExpression("[range(10)] | length", limits: JQLimits(maxDuration: duration))
            XCTAssertEqual(try e.first(.null), .number(10))
        }
    }

    func testExpressionsKeepDefinedFunctionsAlive() throws {
        func make() throws -> JQExpression {
            var functions = JQFunctions()
            try functions.define("def twice: . * 2; def quad: twice | twice;")
            return try JQExpression("quad", functions: functions)
        }
        let e = try make()
        XCTAssertEqual(try e.first(3), .number(12))
    }

    func testDeepJSONIsRejectedWhenParsing() {
        let deep = String(repeating: "[", count: 300) + String(repeating: "]", count: 300)
        XCTAssertThrowsError(try JQValue.parse(deep))
        XCTAssertNoThrow(try JQValue.parse(deep, maxDepth: 400))
        XCTAssertEqual(error(#""\#(deep)" | fromjson"#)?.kind, .runtime)
    }

    func testParserNestingLimit() {
        let deep = String(repeating: "(", count: 400) + "1" + String(repeating: ")", count: 400)
        XCTAssertThrowsError(try JQExpression(deep)) { error in
            XCTAssertEqual((error as? JQError)?.kind, .syntax)
        }
        let fine = String(repeating: "(", count: 100) + "1" + String(repeating: ")", count: 100)
        XCTAssertNoThrow(try JQExpression(fine))
    }

    func testInterpolationCountsTowardsTheNestingLimit() {
        func nested(_ n: Int) -> String {
            String(repeating: #""\("#, count: n) + "1" + String(repeating: #")""#, count: n)
        }
        XCTAssertEqual(try one(nested(50)), .string("1"))
        for n in [300, 20_000] {
            XCTAssertThrowsError(try JQExpression(nested(n)), "\(n)") { error in
                XCTAssertEqual((error as? JQError)?.kind, .syntax)
            }
        }
        let mixed = #""\("# + String(repeating: "(", count: 200) + #""\("# + String(repeating: "(", count: 200)
            + "1" + String(repeating: ")", count: 200) + #")""# + String(repeating: ")", count: 200) + #")""#
        XCTAssertThrowsError(try JQExpression(mixed))
    }

    func testDatetimeFieldsThatAreNotFiniteAreRejected() {
        XCTAssertEqual(error("[nan,0,0,0,0,0,0,0] | mktime")?.kind, .runtime)
        XCTAssertEqual(error("[0,0,0,0,0,infinite,0,0] | strftime(\"%S\")")?.kind, .runtime)
        XCTAssertNoThrow(try run("[0,0,0,0,0,1e300,0,0] | strftime(\"%S\")"))
    }

    func testLongListsDoNotNestDeeply() throws {
        let literals = "[" + (0..<20_000).map(String.init).joined(separator: ",") + "] | length"
        XCTAssertEqual(try one(literals), .number(20_000))
        let computed = "[" + (0..<5_000).map { "(. + \($0))" }.joined(separator: ",") + "] | add"
        XCTAssertEqual(try one(computed, 0), .number(12_497_500))
    }

    func testConcurrentEvaluationOfOneExpression() throws {
        let e = try JQExpression(#"[.[] | select(test("^a"; "i")) | ascii_upcase] | join(",")"#)
        let input: JQValue = ["apple", "Avocado", "banana", "apricot"]
        var results = [JQValue?](repeating: nil, count: 64)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            let r = try? e.first(input)
            lock.lock()
            results[i] = r
            lock.unlock()
        }
        XCTAssertEqual(Set(results.map { $0?.jsonText() ?? "nil" }), [#""APPLE,AVOCADO,APRICOT""#])
    }

    // MARK: Values

    func testNumberFormattingMatchesJQ() {
        let cases: [(Double, String)] = [
            (0, "0"), (-0.0, "0"), (1, "1"), (-1.5, "-1.5"), (100, "100"), (1e15, "1000000000000000"),
            (1e16, "1e+16"), (1e17, "1e+17"), (1.5e300, "1.5e+300"), (123456789.123, "123456789.123"),
            (12345678901234567890, "12345678901234567000"), (0.0001, "0.0001"), (0.000123, "0.000123"),
            (1e-5, "1e-05"), (1.5e-7, "1.5e-07"), (5e-324, "5e-324"), (0.1 + 0.2, "0.30000000000000004"),
            (1.0 / 3, "0.3333333333333333"), (.infinity, "1.7976931348623157e+308"),
            (-.infinity, "-1.7976931348623157e+308"), (.nan, "null"), (1e21, "1e+21"),
        ]
        for (d, s) in cases {
            XCTAssertEqual(JQValue.formatNumber(d), s, "\(d)")
        }
    }

    func testParsingKeepsKeyOrder() throws {
        let v = try JQValue.parse(#"{"b": 1, "a": {"z": true, "y": null}, "c": [1.5, "x"]}"#)
        XCTAssertEqual(v.jsonText(), #"{"b":1,"a":{"z":true,"y":null},"c":[1.5,"x"]}"#)
        XCTAssertEqual(try JQExpression("keys_unsorted").first(v), ["b", "a", "c"])
        XCTAssertEqual(try JQExpression("keys").first(v), ["a", "b", "c"])
        XCTAssertEqual(try JQExpression("[to_entries[].key]").first(v), ["b", "a", "c"])
        XCTAssertEqual(try JQExpression("tojson").first(v), #"{"b":1,"a":{"z":true,"y":null},"c":[1.5,"x"]}"#)
    }

    func testParsingData() throws {
        XCTAssertEqual(try JQValue.parse(Data("\u{FEFF}[1, 2]".utf8)), [1, 2])
        XCTAssertThrowsError(try JQValue.parse("[1, 2")) { error in
            XCTAssertEqual((error as? JQError)?.message, "Unfinished JSON term at EOF at line 1, column 5")
        }
        XCTAssertThrowsError(try JQValue.parse("1 2"))
        XCTAssertThrowsError(try JQValue.parse(""))
        XCTAssertEqual(try JQValue.parse(#""😀é""#), "😀é")
    }

    func testPrettyPrinting() {
        let v: JQValue = ["b": [1, 2], "a": [:], "c": []]
        XCTAssertEqual(v.jsonText(indent: 2), "{\n  \"b\": [\n    1,\n    2\n  ],\n  \"a\": {},\n  \"c\": []\n}")
        XCTAssertEqual(v.jsonText(sortKeys: true), #"{"a":{},"b":[1,2],"c":[]}"#)
    }

    func testEqualityIsJQs() throws {
        let a = try JQValue.parse(#"{"a":1,"b":2}"#)
        let b = try JQValue.parse(#"{"b":2,"a":1.0}"#)
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isIdentical(to: b))
        XCTAssertNotEqual(JQValue.number(.nan), .number(.nan))
        XCTAssertTrue(JQValue.number(.nan).isIdentical(to: .number(.nan)))
        XCTAssertLessThan(JQValue.null, false)
        XCTAssertLessThan(JQValue.number(.nan), -1e300)
        XCTAssertLessThan(JQValue.string("Z"), "a")
    }

    func testConversionFromAnyJSON() throws {
        let config = try AnyJSON.parse(Data(#"{"n": 3, "d": 1.5, "s": "x", "b": true, "z": null, "a": [1]}"#.utf8)).get()
        let v = JQValue(config)
        XCTAssertEqual(v, ["n": 3, "d": 1.5, "s": "x", "b": true, "z": .null, "a": [1]])
        XCTAssertEqual(v.anyJSON, config)
    }

    func testConversionFromFoundation() throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"{"t": true, "f": false, "i": 1, "d": 2.5, "n": null, "a": ["x"]}"#.utf8))
        let v = JQValue(foundation: object)
        XCTAssertEqual(v, ["t": true, "f": false, "i": 1, "d": 2.5, "n": .null, "a": ["x"]])
        let back = v.foundationObject as? [String: Any]
        XCTAssertEqual(back?["i"] as? Int, 1)
        XCTAssertEqual(back?["t"] as? Bool, true)
        XCTAssertTrue(back?["n"] is NSNull)
    }

    // MARK: Deliberate differences from jq 1.7.1

    func testNumberLiteralsAreCanonical() throws {
        // jq 1.7 would print 1.000 and 1E+2 as written.
        XCTAssertEqual(try texts("1.000, 1E+2, [-0]"), ["1", "100", "[0]"])
    }

    func testStringOffsetsAreCodePoints() throws {
        // jq 1.7.1 returns byte offsets from index/indices on non-ASCII text.
        XCTAssertEqual(try one(#""héllo" | index("l")"#), .number(2))
        XCTAssertEqual(try one(#""héllo" | [indices("l")]"#), [[2, 3]])
        // jq 1.7.1 steps through astral characters byte by byte here.
        XCTAssertEqual(try one(#""😀a1" | [match(""; "g") | .offset]"#), [0, 1, 2, 3])
    }

    func testExtensionsBeyondJQ171() throws {
        XCTAssertEqual(try one("[[1,[2]] | leaf_paths]"), [[0], [1, 0]])
        XCTAssertEqual(try one("[72, 105] | map(ascii) | join(\"\")"), "Hi")
        XCTAssertEqual(try one("[1, [2]] | map(toarray)"), [[1], [2]])
        XCTAssertEqual(try one(#""hi" | @base32"#), "NBUQ====")
        XCTAssertEqual(try one(#""NBUQ====" | @base32d"#), "hi")
        XCTAssertEqual(try one("[1,2,3] | add(.[] * 2)"), .number(12))
    }

    func testStrptimeWithoutADateNormalises() throws {
        // jq on macOS reports day 0 here; vestal normalizes through timegm.
        XCTAssertEqual(try one(#""11:30 PM" | strptime("%I:%M %p")"#), [1900, 0, 1, 23, 30, 0, 1, 0])
    }

    func testRegexNamesAndBackreferences() throws {
        // ICU group names cannot hold '_'; names are rewritten internally.
        XCTAssertEqual(try one(#""ada lovelace" | capture("(?<first_name>\\w+) (?<last_name>\\w+)")"#),
                       ["first_name": "ada", "last_name": "lovelace"])
        XCTAssertEqual(try one(#""abab" | test("(?<x>ab)\\k<x>")"#), true)
        XCTAssertEqual(try one(#""a-b" | [scan("[a-z]")]"#), ["a", "b"])
        XCTAssertEqual(try one(#""x.y" | split("."; null)"#), ["", "", "", ""])
    }

    // MARK: Legacy paths

    func testNormalizeLegacyPath() {
        let cases: [(String, String)] = [
            ("rates.BRL", ".rates.BRL"),
            (".nearest_area[0].areaName[0].value", ".nearest_area[0].areaName[0].value"),
            ("items[2].name", ".items[2].name"),
            ("BRL-X.rate", #"."BRL-X".rate"#),
            ("current_condition[0].temp_C", ".current_condition[0].temp_C"),
            ("length", ".length"),
            ("rates | keys", ".rates | keys"),
            ("[0].name", ".[0].name"),
            ("", "."),
            ("  rates.EUR ", ".rates.EUR"),
            (".", "."),
            (".a | length", ".a | length"),
        ]
        for (legacy, expected) in cases {
            XCTAssertEqual(JQExpression.normalizeLegacyPath(legacy), expected, legacy)
            XCTAssertNoThrow(try JQExpression(JQExpression.normalizeLegacyPath(legacy)), legacy)
        }
    }

    func testNormalizedLegacyPathsReadTheSameValuesAsJSONPath() throws {
        let weather = try Fixture.data("wttr-j1.json")
        let rates = try Fixture.data("exchange-rates.json")
        let paths: [(Data, String)] = [
            (weather, ".nearest_area[0].areaName[0].value"),
            (weather, "current_condition[0].temp_C"),
            (weather, "weather[0].astronomy[0].sunrise"),
            (rates, "rates.BRL"),
            (rates, "base"),
        ]
        for (data, path) in paths {
            let legacy = JSONPath.resolve(path, in: try JSONSerialization.jsonObject(with: data))
            XCTAssertNotNil(legacy, path)
            let value = try JQExpression(JQExpression.normalizeLegacyPath(path)).first(try JQValue.parse(data))
            XCTAssertEqual(value, JQValue(foundation: legacy), path)
        }
    }
}
