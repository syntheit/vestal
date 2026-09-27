import Foundation

// MARK: - AST

indirect enum JQAST {
    case identity
    case recurseDefault                       // ..
    case field(JQAST, String)                 // term.name
    case index(JQAST, JQAST)                  // term[expr]
    case slice(JQAST, JQAST?, JQAST?)         // term[a:b]
    case iterate(JQAST)                       // term[]
    case optional(JQAST)                      // term?
    case literal(JQValue)
    case string([JQASTStrPart], format: String?, offset: Int)
    case format(String, offset: Int)          // @name applied to .
    case array(JQAST?)
    case object([JQASTObjEntry])
    case neg(JQAST)
    case binary(String, JQAST, JQAST)         // + - * / % == != < <= > >=
    case and(JQAST, JQAST)
    case or(JQAST, JQAST)
    case alternative(JQAST, JQAST)            // //
    case assign(String, JQAST, JQAST)         // = |= += -= *= /= %= //=
    case pipe(JQAST, JQAST)
    case comma(JQAST, JQAST)
    case ifThen([(JQAST, JQAST)], JQAST?)
    case tryCatch(JQAST, JQAST?)
    case reduce(JQAST, JQPatternAST, JQAST, JQAST)
    case foreach(JQAST, JQPatternAST, JQAST, JQAST, JQAST?)
    case bind(JQAST, [JQPatternAST], JQAST)   // term as p1 ?// p2 | body
    case label(String, JQAST)
    case breakLabel(String, offset: Int)
    case funcDef(JQFuncDefAST, JQAST)
    case call(String, [JQAST], offset: Int)
    case variable(String, offset: Int)
    case loc(line: Int)
}

enum JQASTStrPart {
    case literal(String)
    case interpolation(JQAST)
}

struct JQASTObjEntry {
    var key: JQAST
    /// nil: `{"a"}` / `{"\(x)"}` shorthand; the value is `.[key]`.
    var value: JQAST?
}

struct JQFuncDefAST {
    var name: String
    var params: [(name: String, isValue: Bool)]
    var body: JQAST
    var offset: Int
}

indirect enum JQPatternAST {
    case variable(String, offset: Int)
    case array([JQPatternAST])
    case object([(key: JQPatternKey, value: JQPatternAST?)])
}

enum JQPatternKey {
    case variable(String, offset: Int)   // $name: binds $name to .[name]
    case expr(JQAST)                     // literal, interpolated string or (expr)
}

// MARK: - Parser
//
// Recursive descent with precedence climbing, following jq 1.7's grammar:
//
//   |  (right)  <  ,  <  // (right)  <  = |= += ... (nonassoc)  <  or  <  and
//   <  == != < <= > >= (nonassoc)  <  + -  <  * / %
//
// `Term as $x | body`, `def`, and `label` extend as far right as possible.
// `try` binds tighter than any binary operator. Object values are terms or
// pipes of terms, as in jq (`{a: 1 + 2}` is a syntax error there too).

struct JQParser {
    let src: [Unicode.Scalar]
    var tokens: [JQToken]
    var i = 0
    var nesting = 0
    static let maxNesting = 256

    init(source: [Unicode.Scalar], tokens: [JQToken]) {
        self.src = source
        self.tokens = tokens
    }

    static func parse(_ source: String) throws -> JQAST {
        let scalars = Array(source.unicodeScalars)
        let tokens = try JQLexer.tokenize(scalars)
        var p = JQParser(source: scalars, tokens: tokens)
        if p.peek.tok == .eof {
            throw JQError.at(.syntax, "empty expression (use . for the input itself)", source: scalars, offset: 0)
        }
        let ast = try p.parsePipe()
        try p.expectEOF()
        return ast
    }

    // MARK: Token helpers

    var peek: JQToken { tokens[i] }
    func peek(_ k: Int) -> JQToken { tokens[min(i + k, tokens.count - 1)] }

    mutating func advance() -> JQToken {
        let t = tokens[i]
        if i < tokens.count - 1 { i += 1 }
        return t
    }

    func isOp(_ op: String) -> Bool { peek.tok == .op(op) }
    func isKeyword(_ k: String) -> Bool { peek.tok == .keyword(k) }

    func describe(_ t: JQToken) -> String {
        switch t.tok {
        case .dot: return "'.'"
        case .dotdot: return "'..'"
        case .field(let f): return "'.\(f)'"
        case .ident(let s): return "'\(s)'"
        case .keyword(let k): return "keyword '\(k)'"
        case .variable(let v): return "'$\(v)'"
        case .number(let d): return "number \(JQValue.formatNumber(d))"
        case .string: return "string literal"
        case .format(let f): return "'@\(f)'"
        case .op(let o): return "'\(o)'"
        case .eof: return "end of expression"
        }
    }

    func error(_ message: String, at t: JQToken? = nil) -> JQError {
        JQError.at(.syntax, message, source: src, offset: (t ?? peek).start)
    }

    func unexpected(_ expecting: String? = nil) -> JQError {
        var m = "unexpected \(describe(peek))"
        if let expecting { m += ", expecting \(expecting)" }
        return error(m)
    }

    mutating func expectOp(_ op: String, _ context: String? = nil) throws {
        guard isOp(op) else {
            throw unexpected("'\(op)'" + (context.map { " \($0)" } ?? ""))
        }
        _ = advance()
    }

    mutating func expectKeyword(_ k: String, _ context: String? = nil) throws {
        guard isKeyword(k) else {
            throw unexpected("'\(k)'" + (context.map { " \($0)" } ?? ""))
        }
        _ = advance()
    }

    mutating func expectEOF() throws {
        guard peek.tok == .eof else {
            if isOp("?//") {
                throw error("'?//' only separates alternative patterns after 'as'; for a default value write '(.a?) // x'")
            }
            if isOp(")") { throw error("unmatched ')'") }
            if isOp("]") { throw error("unmatched ']'") }
            if isOp("}") { throw error("unmatched '}'") }
            if isOp(";") { throw error("unexpected ';' (';' separates function arguments and ends 'def')") }
            throw unexpected()
        }
    }

    func line(of offset: Int) -> Int {
        var line = 1
        for k in 0..<min(offset, src.count) where src[k] == "\n" { line += 1 }
        return line
    }

    // MARK: Expressions

    enum Assoc { case left, right, none }

    func binaryOp(_ t: JQToken) -> (op: String, prec: Int, assoc: Assoc)? {
        switch t.tok {
        case .op(let o):
            switch o {
            case "|": return (o, 1, .right)
            case ",": return (o, 2, .left)
            case "//": return (o, 3, .right)
            case "=", "|=", "+=", "-=", "*=", "/=", "%=", "//=": return (o, 4, .none)
            case "==", "!=", "<", "<=", ">", ">=": return (o, 7, .none)
            case "+", "-": return (o, 8, .left)
            case "*", "/", "%": return (o, 9, .left)
            default: return nil
            }
        case .keyword("or"): return ("or", 5, .left)
        case .keyword("and"): return ("and", 6, .left)
        default: return nil
        }
    }

    mutating func parsePipe() throws -> JQAST { try parseBinary(1) }

    mutating func parseBinary(_ minPrec: Int) throws -> JQAST {
        nesting += 1
        defer { nesting -= 1 }
        if nesting > JQParser.maxNesting {
            throw error("expression nested too deeply (more than \(JQParser.maxNesting) levels)")
        }
        var lhs = try parseUnary()
        while case let (op, prec, assoc)? = binaryOp(peek), prec >= minPrec {
            let opToken = advance()
            if peek.tok == .eof || isOp(")") || isOp("]") || isOp("}") || isOp(";") {
                throw error("missing right-hand side of '\(op)'", at: peek)
            }
            if op == "," {
                // A run of commas becomes a balanced tree (`,` is
                // associative), so long lists do not nest deeply.
                var items = [lhs, try parseBinary(prec + 1)]
                while isOp(",") {
                    _ = advance()
                    if peek.tok == .eof || isOp(")") || isOp("]") || isOp("}") || isOp(";") {
                        throw error("missing right-hand side of ','", at: peek)
                    }
                    items.append(try parseBinary(prec + 1))
                }
                lhs = JQParser.balancedComma(items[...])
                continue
            }
            let rhs = try parseBinary(assoc == .right ? prec : prec + 1)
            if assoc == .none, let next = binaryOp(peek), next.prec == prec {
                throw error("'\(next.op)' cannot follow '\(op)' without parentheses (these operators do not chain)")
            }
            lhs = combine(op, lhs, rhs)
            _ = opToken
        }
        return lhs
    }

    static func balancedComma(_ items: ArraySlice<JQAST>) -> JQAST {
        if items.count == 1 { return items[items.startIndex] }
        let mid = items.startIndex + items.count / 2
        return .comma(balancedComma(items[..<mid]), balancedComma(items[mid...]))
    }

    func combine(_ op: String, _ l: JQAST, _ r: JQAST) -> JQAST {
        switch op {
        case "|": return .pipe(l, r)
        case ",": return .comma(l, r)
        case "//": return .alternative(l, r)
        case "and": return .and(l, r)
        case "or": return .or(l, r)
        case "=", "|=", "+=", "-=", "*=", "/=", "%=", "//=": return .assign(op, l, r)
        default: return .binary(op, l, r)
        }
    }

    mutating func parseUnary() throws -> JQAST {
        if isOp("-") {
            _ = advance()
            let operand = try parseBinary(9)
            if case .literal(.number(let d)) = operand { return .literal(.number(-d)) }
            return .neg(operand)
        }
        if isKeyword("def") {
            let def = try parseFuncDef()
            let body = try parsePipe()
            return .funcDef(def, body)
        }
        if isKeyword("label") {
            _ = advance()
            guard case .variable(let name) = peek.tok else { throw unexpected("a '$name' after 'label'") }
            _ = advance()
            try expectOp("|", "after 'label $\(name)'")
            return .label(name, try parsePipe())
        }
        return try parsePostfix(allowAs: true)
    }

    // MARK: Terms

    mutating func parsePostfix(allowAs: Bool) throws -> JQAST {
        var term = try parsePrimary()
        while true {
            switch peek.tok {
            case .field(let name):
                _ = advance()
                term = .field(term, name)
            case .dot:
                // term."key" and term.[...] (jq 1.7)
                if case .string = peek(1).tok {
                    _ = advance()
                    term = .index(term, try parseStringToken(format: nil))
                } else if peek(1).tok == .op("[") {
                    _ = advance()
                    term = try parseBracketSuffix(term)
                } else {
                    return term
                }
            case .op("["):
                term = try parseBracketSuffix(term)
            case .op("?"):
                _ = advance()
                term = .optional(term)
            case .keyword("as") where allowAs:
                _ = advance()
                let patterns = try parsePatterns()
                try expectOp("|", "after the 'as' binding")
                let body = try parsePipe()
                return .bind(term, patterns, body)
            default:
                return term
            }
        }
    }

    mutating func parseBracketSuffix(_ term: JQAST) throws -> JQAST {
        try expectOp("[")
        if isOp("]") {
            _ = advance()
            return .iterate(term)
        }
        if isOp(":") {
            _ = advance()
            let to = try parsePipe()
            try expectOp("]", "to close the slice")
            return .slice(term, nil, to)
        }
        let e = try parsePipe()
        if isOp(":") {
            _ = advance()
            if isOp("]") {
                _ = advance()
                return .slice(term, e, nil)
            }
            let to = try parsePipe()
            try expectOp("]", "to close the slice")
            return .slice(term, e, to)
        }
        try expectOp("]", "to close the index")
        return .index(term, e)
    }

    mutating func parsePrimary() throws -> JQAST {
        let t = peek
        switch t.tok {
        case .dot:
            _ = advance()
            if case .string = peek.tok {
                return .index(.identity, try parseStringToken(format: nil))
            }
            if isOp("[") { return try parseBracketSuffix(.identity) }
            return .identity
        case .dotdot:
            _ = advance()
            return .recurseDefault
        case .field(let name):
            _ = advance()
            return .field(.identity, name)
        case .number(let d):
            _ = advance()
            return .literal(.number(d))
        case .string:
            return try parseStringToken(format: nil)
        case .format(let name):
            _ = advance()
            if case .string = peek.tok { return try parseStringToken(format: (name, t.start)) }
            return .format(name, offset: t.start)
        case .variable(let name):
            _ = advance()
            if name == "__loc__" { return .loc(line: line(of: t.start)) }
            return .variable(name, offset: t.start)
        case .op("("):
            _ = advance()
            if isOp(")") { throw error("empty parentheses") }
            let e = try parsePipe()
            try expectOp(")", "to close '('")
            return e
        case .op("["):
            _ = advance()
            if isOp("]") { _ = advance(); return .array(nil) }
            let e = try parsePipe()
            try expectOp("]", "to close '['")
            return .array(e)
        case .op("{"):
            return try parseObject()
        case .ident(let name):
            _ = advance()
            if name.contains("::") { throw error("modules are not supported ('\(name)')", at: t) }
            if !isOp("(") {
                switch name {
                case "true": return .literal(.bool(true))
                case "false": return .literal(.bool(false))
                case "null": return .literal(.null)
                default: break
                }
            }
            var args: [JQAST] = []
            if isOp("(") {
                _ = advance()
                while true {
                    args.append(try parsePipe())
                    if isOp(";") { _ = advance(); continue }
                    if isOp(")") { _ = advance(); break }
                    if isOp(",") {
                        throw error("unexpected ','; function arguments are separated by ';', e.g. f(a; b)")
                    }
                    throw unexpected("';' or ')' in the argument list of \(name)")
                }
            }
            return .call(name, args, offset: t.start)
        case .keyword(let k):
            switch k {
            case "if": return try parseIf()
            case "try":
                _ = advance()
                let body = try parsePostTerm()
                if isKeyword("catch") {
                    _ = advance()
                    return .tryCatch(body, try parsePostTerm())
                }
                return .tryCatch(body, nil)
            case "reduce":
                _ = advance()
                let source = try parsePostfix(allowAs: false)
                try expectKeyword("as", "after the 'reduce' source")
                let pattern = try parsePattern()
                try expectOp("(", "after 'reduce ... as $x'")
                let initial = try parsePipe()
                try expectOp(";", "between the reduce initial value and update")
                let update = try parsePipe()
                try expectOp(")", "to close 'reduce'")
                return .reduce(source, pattern, initial, update)
            case "foreach":
                _ = advance()
                let source = try parsePostfix(allowAs: false)
                try expectKeyword("as", "after the 'foreach' source")
                let pattern = try parsePattern()
                try expectOp("(", "after 'foreach ... as $x'")
                let initial = try parsePipe()
                try expectOp(";", "between the foreach initial value and update")
                let update = try parsePipe()
                var extract: JQAST?
                if isOp(";") {
                    _ = advance()
                    extract = try parsePipe()
                }
                try expectOp(")", "to close 'foreach'")
                return .foreach(source, pattern, initial, update, extract)
            case "def", "label":
                return try parseUnary()
            case "break":
                _ = advance()
                guard case .variable(let name) = peek.tok else { throw unexpected("a '$name' after 'break'") }
                let v = advance()
                return .breakLabel(name, offset: v.start)
            case "import", "include":
                throw error("modules are not supported ('\(k)')")
            default:
                throw unexpected()
            }
        case .op("-"):
            return try parseUnary()
        case .eof:
            throw error("unexpected end of expression")
        default:
            throw unexpected()
        }
    }

    /// The body of `try` and `catch`: a term with suffixes (jq's "try" binds
    /// tighter than every binary operator).
    mutating func parsePostTerm() throws -> JQAST {
        if isOp("-") {
            _ = advance()
            return .neg(try parsePostfix(allowAs: false))
        }
        return try parsePostfix(allowAs: false)
    }

    mutating func parseIf() throws -> JQAST {
        try expectKeyword("if")
        var branches: [(JQAST, JQAST)] = []
        let cond = try parsePipe()
        try expectKeyword("then", "after the 'if' condition")
        branches.append((cond, try parsePipe()))
        while isKeyword("elif") {
            _ = advance()
            let c = try parsePipe()
            try expectKeyword("then", "after the 'elif' condition")
            branches.append((c, try parsePipe()))
        }
        var elseBranch: JQAST?
        if isKeyword("else") {
            _ = advance()
            elseBranch = try parsePipe()
        }
        try expectKeyword("end", "to close 'if'")
        return .ifThen(branches, elseBranch)
    }

    // MARK: Strings

    /// A string token (possibly interpolated) as an AST node.
    mutating func parseStringToken(format: (String, Int)?) throws -> JQAST {
        let t = advance()
        guard case .string(let parts) = t.tok else { throw unexpected("a string") }
        var out: [JQASTStrPart] = []
        for part in parts {
            switch part {
            case .literal(let s): out.append(.literal(s))
            case .interpolation(let toks):
                var sub = JQParser(source: src, tokens: toks)
                sub.nesting = nesting
                if sub.peek.tok == .eof { throw sub.error("empty string interpolation \\()") }
                let e = try sub.parsePipe()
                try sub.expectEOF()
                out.append(.interpolation(e))
            }
        }
        if format == nil, out.count == 1, case .literal(let s) = out[0] {
            return .literal(.string(s))
        }
        if format == nil, out.isEmpty { return .literal(.string("")) }
        return .string(out, format: format?.0, offset: format?.1 ?? t.start)
    }

    // MARK: Objects

    mutating func parseObject() throws -> JQAST {
        try expectOp("{")
        var entries: [JQASTObjEntry] = []
        while !isOp("}") {
            let t = peek
            switch t.tok {
            case .variable(let name):
                _ = advance()
                if name == "__loc__" {
                    entries.append(JQASTObjEntry(key: .literal(.string("__loc__")), value: .loc(line: line(of: t.start))))
                } else if isOp(":") {
                    _ = advance()
                    entries.append(JQASTObjEntry(key: .variable(name, offset: t.start), value: try parseObjectValue()))
                } else {
                    entries.append(JQASTObjEntry(key: .literal(.string(name)), value: .variable(name, offset: t.start)))
                }
            case .ident(let name), .keyword(let name):
                _ = advance()
                if isOp(":") {
                    _ = advance()
                    entries.append(JQASTObjEntry(key: .literal(.string(name)), value: try parseObjectValue()))
                } else {
                    entries.append(JQASTObjEntry(key: .literal(.string(name)), value: .field(.identity, name)))
                }
            case .string:
                let key = try parseStringToken(format: nil)
                if isOp(":") {
                    _ = advance()
                    entries.append(JQASTObjEntry(key: key, value: try parseObjectValue()))
                } else {
                    entries.append(JQASTObjEntry(key: key, value: nil))
                }
            case .format(let f):
                _ = advance()
                guard case .string = peek.tok else { throw error("unexpected '@\(f)' as an object key") }
                let key = try parseStringToken(format: (f, t.start))
                if isOp(":") {
                    _ = advance()
                    entries.append(JQASTObjEntry(key: key, value: try parseObjectValue()))
                } else {
                    entries.append(JQASTObjEntry(key: key, value: nil))
                }
            case .number:
                throw error("object keys must be identifiers or strings; write {\"\(describeNumber(t))\": ...} or {(expr): ...}")
            case .op("("):
                _ = advance()
                let key = try parsePipe()
                try expectOp(")", "to close the computed key")
                try expectOp(":", "after the computed key")
                entries.append(JQASTObjEntry(key: key, value: try parseObjectValue()))
            default:
                throw unexpected("an object key")
            }
            if isOp(",") { _ = advance(); continue }
            if isOp("}") { break }
            if case .op(let o) = peek.tok, binaryOp(peek) != nil, o != "|" {
                throw error("unexpected '\(o)' in object value; an object value must be a term or a pipe of terms, so wrap it in parentheses, e.g. {key: (.a \(o) .b)}")
            }
            throw unexpected("',' or '}' in object")
        }
        _ = advance()
        return .object(entries)
    }

    func describeNumber(_ t: JQToken) -> String {
        if case .number(let d) = t.tok { return JQValue.formatNumber(d) }
        return ""
    }

    /// jq's ExpD: `ExpD | ExpD`, `-ExpD`, or a term.
    mutating func parseObjectValue() throws -> JQAST {
        var v = try parseObjectValueTerm()
        while isOp("|") {
            _ = advance()
            v = .pipe(v, try parseObjectValueTerm())
        }
        return v
    }

    mutating func parseObjectValueTerm() throws -> JQAST {
        if isOp("-") {
            _ = advance()
            let operand = try parseObjectValueTerm()
            if case .literal(.number(let d)) = operand { return .literal(.number(-d)) }
            return .neg(operand)
        }
        if peek.tok == .op("}") || peek.tok == .op(",") || peek.tok == .eof {
            throw unexpected("an object value")
        }
        return try parsePostfix(allowAs: false)
    }

    // MARK: Patterns

    mutating func parsePatterns() throws -> [JQPatternAST] {
        var patterns = [try parsePattern()]
        while isOp("?//") {
            _ = advance()
            patterns.append(try parsePattern())
        }
        return patterns
    }

    mutating func parsePattern() throws -> JQPatternAST {
        let t = peek
        switch t.tok {
        case .variable(let name):
            _ = advance()
            if name == "__loc__" { throw error("cannot bind to $__loc__", at: t) }
            return .variable(name, offset: t.start)
        case .op("["):
            _ = advance()
            var elems: [JQPatternAST] = []
            if isOp("]") { throw error("empty array pattern") }
            while true {
                elems.append(try parsePattern())
                if isOp(",") { _ = advance(); continue }
                try expectOp("]", "to close the array pattern")
                break
            }
            return .array(elems)
        case .op("{"):
            _ = advance()
            var entries: [(key: JQPatternKey, value: JQPatternAST?)] = []
            while true {
                let k = peek
                switch k.tok {
                case .variable(let name):
                    _ = advance()
                    var sub: JQPatternAST?
                    if isOp(":") { _ = advance(); sub = try parsePattern() }
                    entries.append((.variable(name, offset: k.start), sub))
                case .ident(let name), .keyword(let name):
                    _ = advance()
                    try expectOp(":", "after the key '\(name)' in the object pattern")
                    entries.append((.expr(.literal(.string(name))), try parsePattern()))
                case .string:
                    let key = try parseStringToken(format: nil)
                    try expectOp(":", "after the key in the object pattern")
                    entries.append((.expr(key), try parsePattern()))
                case .op("("):
                    _ = advance()
                    let key = try parsePipe()
                    try expectOp(")", "to close the computed key")
                    try expectOp(":", "after the computed key")
                    entries.append((.expr(key), try parsePattern()))
                default:
                    throw unexpected("a key in the object pattern")
                }
                if isOp(",") { _ = advance(); continue }
                try expectOp("}", "to close the object pattern")
                break
            }
            return .object(entries)
        default:
            throw unexpected("a pattern ($name, [...] or {...})")
        }
    }

    // MARK: Definitions

    mutating func parseFuncDef() throws -> JQFuncDefAST {
        let defToken = advance()
        guard case .ident(let name) = peek.tok else {
            if case .keyword(let k) = peek.tok { throw error("'\(k)' is a keyword and cannot be a function name") }
            throw unexpected("a function name after 'def'")
        }
        _ = advance()
        var params: [(name: String, isValue: Bool)] = []
        if isOp("(") {
            _ = advance()
            while true {
                switch peek.tok {
                case .ident(let p): _ = advance(); params.append((p, false))
                case .variable(let p): _ = advance(); params.append((p, true))
                default: throw unexpected("a parameter name")
                }
                if isOp(";") { _ = advance(); continue }
                try expectOp(")", "to close the parameter list")
                break
            }
        }
        try expectOp(":", "after 'def \(name)'")
        let body = try parsePipe()
        try expectOp(";", "to end the definition of \(name)")
        return JQFuncDefAST(name: name, params: params, body: body, offset: defToken.start)
    }
}
