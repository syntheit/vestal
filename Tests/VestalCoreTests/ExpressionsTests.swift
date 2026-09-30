import Foundation
import VestalCore
import XCTest

// Text templates, the expression environment (limits, user functions),
// load-time text, engine-backed source expressions and `vestal eval`.

final class TextTemplateTests: XCTestCase {
    private func parts(_ text: String) throws -> [TextTemplate.Part] {
        switch TextTemplate.parse(text) {
        case .success(let template): return template.parts
        case .failure(let error): throw error
        }
    }

    func testHolesAndLiterals() throws {
        XCTAssertEqual(try parts("a {{ .x }} b"), [.literal("a "), .hole(".x", offset: 5), .literal(" b")])
        XCTAssertEqual(try parts("{{.x}}{{ .y }}"), [.hole(".x", offset: 2), .hole(".y", offset: 9)])
        XCTAssertEqual(try parts("plain"), [.literal("plain")])
        XCTAssertTrue(try TextTemplate.parse("plain").get().isLiteral)
        XCTAssertFalse(try TextTemplate.parse("a {{ 1 }}").get().isLiteral)
    }

    func testEscapedBraces() throws {
        XCTAssertEqual(try parts("a {{{{ b"), [.literal("a {{ b")])
        XCTAssertEqual(try parts("{{{{ .x }}"), [.literal("{{ .x }}")])
        XCTAssertEqual(TextTemplate.escape("x {{ y"), "x {{{{ y")
    }

    func testBracesAndStringsInsideAHole() throws {
        XCTAssertEqual(try parts("{{ {a: {b: 1}} | .a.b }}!"), [.hole("{a: {b: 1}} | .a.b", offset: 3), .literal("!")])
        XCTAssertEqual(try parts(#"{{ "}}" }}"#), [.hole(#""}}""#, offset: 3)])
        XCTAssertEqual(try parts(#"{{ "\(.a)}}" }}"#), [.hole(#""\(.a)}}""#, offset: 3)])
    }

    func testUnclosedAndEmptyHoles() {
        guard case .failure(let error) = TextTemplate.parse("x {{ .a") else { return XCTFail("parsed") }
        XCTAssertEqual(error.offset, 2)
        XCTAssertEqual(error.code, "expr-syntax")
        guard case .failure(let empty) = TextTemplate.parse("x {{ }}") else { return XCTFail("parsed") }
        XCTAssertEqual(empty.code, "expr-syntax")
    }

    func testStringifyFollowsR2() {
        XCTAssertEqual(TextTemplate.stringify(nil), "")
        XCTAssertEqual(TextTemplate.stringify(.null), "")
        XCTAssertEqual(TextTemplate.stringify(.string("s")), "s")
        XCTAssertEqual(TextTemplate.stringify(.number(1.5)), "1.5")
        XCTAssertEqual(TextTemplate.stringify(.number(2)), "2")
        XCTAssertEqual(TextTemplate.stringify(.bool(true)), "true")
        XCTAssertEqual(TextTemplate.stringify(.array([.number(1)])), "[1]")
    }
}

final class ExprEnvironmentTests: XCTestCase {
    private func run(_ source: String, environment: ExprEnvironment = .standard,
                     input: JQValue = .null) -> Result<JQValue?, ExprError> {
        switch environment.compile(source) {
        case .failure(let error): return .failure(error)
        case .success(let expression):
            return environment.first(expression, input: input, variables: [:], context: JQEvalContext())
        }
    }

    func testLimitsStopRunawayExpressions() {
        let start = Date()
        guard case .failure(let range) = run("[range(1e9)] | length") else { return XCTFail("range(1e9) finished") }
        XCTAssertEqual(range.kind, .limit)
        XCTAssertEqual(range.code, "expr-limit")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)

        guard case .failure(let recursion) = run("def f: f + 1; f") else { return XCTFail("recursion finished") }
        XCTAssertEqual(recursion.code, "expr-limit")

        guard case .failure(let huge) = run(#""x" * 5000000"#) else { return XCTFail("huge string accepted") }
        XCTAssertEqual(huge.code, "expr-limit")
        XCTAssertEqual(huge.message, "result larger than 4 MiB")

        XCTAssertEqual(try run("[range(1000)] | length").get(), .number(1000))
    }

    func testCompileErrorsAreClassified() {
        guard case .failure(let unknown) = run(".cpu.percent | rond") else { return XCTFail("compiled") }
        XCTAssertEqual(unknown.kind, .compile)
        XCTAssertEqual(unknown.code, "expr-unknown-function")
        XCTAssertEqual(unknown.message, "unknown function 'rond'")
        XCTAssertEqual(unknown.suggestion, "round")
        XCTAssertEqual(unknown.offset, 15)
        guard case .failure(let syntax) = run(".a |") else { return XCTFail("compiled") }
        XCTAssertEqual(syntax.code, "expr-syntax")
        guard case .failure(let runtime) = run(#""n/a" | tonumber"#) else { return XCTFail("ran") }
        XCTAssertEqual(runtime.kind, .runtime)
        XCTAssertEqual(runtime.code, "expr-runtime")
    }

    func testVestalFunctionsAreRegistered() {
        XCTAssertEqual(try run("3.14159 | fmt_fixed(2)").get(), .string("3.14"))
        XCTAssertTrue(ExprEnvironment.standard.functionNames.contains("fmt_uptime"))
        XCTAssertTrue(ExprEnvironment.standard.functionNames.contains("round"))
    }

    func testUserFunctionsInAnyOrder() {
        // "a" sorts first but calls "b": order comes from the calls, not the keys.
        let environment = ExprEnvironment(userFunctions: ["a": "b + 1", "b": "2", "gib": ". / 1073741824"])
        XCTAssertTrue(environment.functionErrors.isEmpty, "\(environment.functionErrors)")
        XCTAssertEqual(try run("a", environment: environment).get(), .number(3))
        XCTAssertEqual(try run(".size | gib", environment: environment, input: ["size": 2147483648]).get(), .number(2))
        XCTAssertEqual(Set(environment.userFunctionNames), ["a", "b", "gib"])
        XCTAssertTrue(environment.functionNames.contains("gib"))
    }

    func testUserFunctionProblems() {
        let environment = ExprEnvironment(userFunctions: [
            "x": "y", "y": "x",          // a cycle
            "z": "x + 1",                // calls a function with an error
            "Bad-Name": "1",
            "round": "2",                // shadows a builtin
            "fmt_int": "3",              // shadows a vestal function
            "broken": ". |",
            "ok": "1",
        ])
        XCTAssertEqual(environment.functionErrors["x"]?.code, "expr-cycle")
        XCTAssertEqual(environment.functionErrors["y"]?.code, "expr-cycle")
        XCTAssertNotNil(environment.functionErrors["z"])
        XCTAssertEqual(environment.functionErrors["Bad-Name"]?.code, "invalid-value")
        XCTAssertTrue(environment.functionErrors["round"]?.message.contains("shadows") == true)
        XCTAssertTrue(environment.functionErrors["fmt_int"]?.message.contains("shadows") == true)
        XCTAssertEqual(environment.functionErrors["broken"]?.code, "expr-syntax")
        XCTAssertNil(environment.functionErrors["ok"])
        XCTAssertEqual(environment.userFunctionNames, ["ok"])
        // The builtin still means the builtin.
        XCTAssertEqual(try run("2.6 | round", environment: environment).get(), .number(3))
    }
}

final class LoadTimeTextTests: XCTestCase {
    private let lookup: (String) async throws -> String? = { path in
        switch path {
        case "$env.HOME": return "/home/me"
        case "$secrets.token": return "s3cret"
        default: return nil
        }
    }

    func testHolesAreJq() async throws {
        let home = try await LoadTimeText.evaluate(#"{{ $env.HOME + "/x" }}"#, lookup: lookup)
        XCTAssertEqual(home, "/home/me/x")
        let url = try await LoadTimeText.evaluate("https://a.example/?k={{ $secrets.token | ascii_upcase }}", lookup: lookup)
        XCTAssertEqual(url, "https://a.example/?k=S3CRET")
        let escaped = try await LoadTimeText.evaluate("{{{{ literal", lookup: lookup)
        XCTAssertEqual(escaped, "{{ literal")
    }

    func testOnlySecretsAndEnvAreInScope() async {
        for text in ["{{ $data.x }}", "{{ .x | round }}"] {
            do {
                _ = try await LoadTimeText.evaluate(text, lookup: lookup)
                XCTFail("\(text) evaluated")
            } catch let error as SourceError {
                XCTAssertTrue(error.description.contains("only $secrets"), error.description)
            } catch {
                XCTFail("\(error)")
            }
        }
        do {
            _ = try await LoadTimeText.evaluate("{{ $secrets.missing }}", lookup: lookup)
            XCTFail("unknown secret evaluated")
        } catch let error as SourceError {
            XCTAssertTrue(error.description.contains("unknown $secrets.missing"), error.description)
        } catch {
            XCTFail("\(error)")
        }
    }
}

final class EngineSourceExpressionsTests: XCTestCase {
    func testTransformAndNumber() throws {
        let expressions = EngineSourceExpressions()
        let data: AnyJSON = .object(["a": .array([.int(1), .int(2)]), "x": .string("12.5"), "s": .string("n/a")])
        XCTAssertEqual(try expressions.transform(".a | map(. * 2)", data), .array([.int(2), .int(4)]))
        XCTAssertEqual(expressions.number(".x", data), 12.5)
        XCTAssertEqual(expressions.number(".a[1]", data), 2)
        XCTAssertNil(expressions.number(".s", data))
        XCTAssertNil(expressions.number(".a | rond", data))
        XCTAssertThrowsError(try expressions.transform(".s | tonumber", data)) { error in
            XCTAssertTrue("\(error)".contains("transform:"), "\(error)")
        }
    }

    func testUserFunctionsInTransforms() throws {
        let expressions = EngineSourceExpressions(environment: ExprEnvironment(userFunctions: ["double": ". * 2"]))
        XCTAssertEqual(try expressions.transform(".n | double", .object(["n": .int(4)])), .int(8))
    }
}

final class EvalCommandTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = try makeTemporaryDirectory()
    }

    private func eval(_ arguments: [String], stdin: String = "") -> ConfigCommands.Output {
        EvalCommand.run(arguments, environment: [:], home: home.path, platform: SourcePlatform(),
                        client: { _, _ in throw IPCError.notRunning(path: "/nowhere") },
                        cache: SnapshotCache(directory: home.appendingPathComponent("cache").path),
                        stdin: { Data(stdin.utf8) })
    }

    private func input(_ json: String) throws -> String {
        let url = home.appendingPathComponent("input-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url.path
    }

    func testOutputsOnePerLine() throws {
        XCTAssertEqual(eval(["1, \"two\", [3]", "--null-input"]).stdout, "1\n\"two\"\n[3]\n")
        let file = try input(#"{"a": [1, 2], "name": "x"}"#)
        let out = eval([".a[]", "--input", file])
        XCTAssertEqual(out.status, 0)
        XCTAssertEqual(out.stdout, "1\n2\n")
        XCTAssertEqual(eval([".name", "--input", "-"], stdin: #"{"name": "stdin"}"#).stdout, "\"stdin\"\n")
    }

    func testTemplateVarAndJSON() throws {
        let file = try input(#"{"a": [1, 2]}"#)
        XCTAssertEqual(eval(["--template", "{{ .a | length }} items", "--input", file]).stdout, "2 items\n")
        XCTAssertEqual(eval(["$n * 2", "--var", "n=3", "-n"]).stdout, "6\n")
        XCTAssertEqual(eval(["$s", "--var", "s=plain text", "-n"]).stdout, "\"plain text\"\n")
        XCTAssertEqual(eval([".a", "--input", file, "--json"]).stdout, #"{"ok":true,"outputs":[[1,2]]}"# + "\n")
        XCTAssertEqual(eval(["now | fmt_time(\"HH:mm\"; \"UTC\")", "-n", "--at", "2026-09-27T17:03:22Z"]).stdout, "\"17:03\"\n")
    }

    func testCompileErrorWithCaret() {
        let out = eval([".a | rond", "-n"])
        XCTAssertEqual(out.status, 3)
        XCTAssertEqual(out.stderr, """
            vestal: expression error at 1:6: unknown function 'rond'; did you mean 'round'?
              .a | rond
                   ^

            """)
        let json = eval([".a | rond", "-n", "--json"])
        XCTAssertEqual(json.status, 3)
        XCTAssertTrue(json.stdout.contains(#""suggestion":"round""#), json.stdout)
        XCTAssertTrue(json.stdout.contains(#""offset":5"#), json.stdout)
        // In a template, the offset counts from the start of the text.
        let template = eval(["--template", "x {{ .a | rond }}", "-n"])
        XCTAssertEqual(template.status, 3)
        XCTAssertTrue(template.stderr.hasPrefix("vestal: expression error at 1:11:"), template.stderr)
    }

    func testRuntimeErrorsAndExitCodes() {
        let runtime = eval([#""n/a" | tonumber"#, "-n"])
        XCTAssertEqual(runtime.status, 3)
        XCTAssertEqual(eval(["1", "--source", "nosuchsource"]).status, 4)
        XCTAssertEqual(eval([]).status, 2)
        XCTAssertEqual(eval([".", "--frobnicate"]).status, 2)
        XCTAssertEqual(eval([".", "-n", "--input", "x.json"]).status, 2)
    }
}
