# Expression engine (jq)

`VestalCore/Expr` is a jq interpreter written in Swift (Foundation only, no dependencies). It evaluates every data expression in the config: widget values, labels, colors, filters. It follows **jq 1.7.1**. `Tests/VestalCoreTests/Fixtures/expr-cases.json` holds about 1000 cases whose expected output came from the real jq binary; `ExprFixtureTests` replays them.

## API

```swift
let e = try JQExpression(".items[] | select(.ok) | .name")      // compile once
let all = try e.run(input: data)                                // [JQValue], every output
let first = try e.first(data)                                   // JQValue?, stops after the first
try e.forEach(data) { value in ...; return true }               // stream; return false to stop
```

- `JQExpression(_ source:, functions:, variables:, allowFreeVariables:, limits:)`, or `JQExpression.compile(...)`. It throws `JQError`.
- `run(input:variables:context:)`, `evaluate(_:variables:context:)`, `first(_:variables:context:)`, `forEach(_:variables:context:_:)`.
- `variables: ["name"]` declares `$name`s that the caller passes at run time; a declared name that is not passed is null. With `allowFreeVariables: true`, any unbound `$name` compiles and is looked up at run time, and it is an error if it is missing.
- `references` (`JQReferences`) lists what the expression uses from outside: every external `$variable` with the static keys after it (`$sources.system.cpu` gives `["system", "cpu"]`; a dynamic key, `.[]` or a pipe gives `[]`, meaning the whole value), and every builtin or registered function called, with literal arguments (`meta("weather")`). `callsNow` says whether it depends on the clock.
- `JQEvalContext(now:timeZone:userInfo:)`: `now` freezes the `now` builtin; `nowWasCalled` records whether it was used; `timeZone` drives `localtime`/`strflocaltime`; `userInfo` is for registered functions. Use one per evaluation.
- `JQValue`: `null`, `bool`, `number(Double)`, `string`, `array`, `object(JQObject)`. Objects keep insertion order. `JQValue.parse(_:)` parses JSON text or `Data` keeping key order (default depth limit 256); `jsonText(indent:sortKeys:)` prints like jq; `init(_: AnyJSON)`, `anyJSON`, `init(foundation:)` and `foundationObject` convert. `==` is jq's equality; `isIdentical(to:)` is exact, order-sensitive and treats nan as equal to nan.
- `JQError`: `kind` is `.syntax`, `.compile`, `.runtime` or `.limit`, plus `message`. Syntax and compile errors also carry `line`, `column` (1-based), `offset` (UTF-8 bytes) and a caret `snippet`. A runtime error's `value` is what `catch` sees (the object passed to `error({...})`, for example).

### Registering functions

```swift
var f = JQFunctions()
f.register("name", arity: 1) { input, args, context in [/* outputs */] }   // args evaluated as values
f.registerValue("double", arity: 0) { input, _ in .number((input.numberValue ?? 0) * 2) }
f.registerClosure("uniq_by", arity: 1) { input, args, context in           // args are closures
    /* args[0].first(item), args[0].evaluate(item) */ [...]
}
try f.define("def gib: . / 1073741824;")                                    // jq definitions
let e = try JQExpression(".size | gib", functions: f)
```

Value arguments follow jq's C-builtin order: when an argument yields several values, the function runs for every combination, and the last argument varies slowest. Throw `JQError.runtime("...")` for a catchable jq error; any other error becomes a runtime error prefixed with the function name. A registration shadows a builtin with the same name and arity. Definitions may use builtins, registered functions, earlier definitions and any `$variable` that the evaluation supplies, and their references are merged into the references of the expressions that call them.

### Limits (`JQLimits`)

| Limit | Default | Counts |
|---|---|---|
| `maxSteps` | 1,000,000 | each value iterated or generated (`.[]`, `range`, regex matches), each `reduce`/`foreach` iteration, each function call |
| `maxDuration` | 1 s | wall clock, checked every 256 steps |
| `maxDepth` | 20,000 | nested evaluation frames |
| `maxOutputs` | 100,000 | outputs of one evaluation |
| `maxValueSize` | 10,000,000 | largest string (UTF-8 bytes) or array (elements) one operator or builtin may produce: `*` on strings, `+`, `add`, `join`, `tostring`, `tojson`, `@format`, string interpolation, `implode`, `split`, `explode` and array construction |
| `maxRegexSubject` | 1,000,000 | UTF-8 bytes of the string a regex (`test`, `match`, `sub`, `scan`, ...) runs against |
| `maxRegexPattern` | 4,096 | UTF-8 bytes of a regex pattern |

Evaluation also stops before the thread runs out of stack: a guard compares the stack pointer with the thread's bounds. As a result, runaway recursion is a `.limit` error, even on a 512 KiB background-thread stack. In a release build that allows about 550 levels of evaluation nesting on 512 KiB and about 10,000 on the 8 MiB main thread. Values may nest at most 512 levels deep. The wall clock is only checked every 256 steps, so `maxValueSize` bounds what one step can allocate (a string `*` or `+` that would pass it fails before or just after allocating). `setpath` may not create an array index above 10,000,000. `.limit` errors are not catchable by `try` or `?`.

`until`, `while` and `repeat` run as loops when their arguments yield at most one value each, so a 100,000-iteration `until` does not recurse. With generator arguments they fall back to jq's recursive definitions, which gives the same outputs.

## Syntax

All of jq 1.7's expression syntax is supported:
- `.`, `..`, `.foo`, `."key"`, `.[e]`, `.[a:b]`, `.[]`, `?`
- `|`, `,`, `//`, `and`/`or`
- arithmetic and comparisons with jq's type rules
- `if`/`elif`/`else`/`end` (the `else` is optional)
- `try`/`catch`, `reduce`, `foreach` (2 or 3 clauses), `label $x | ... break $x`
- `def f(g; $x): ...;` with recursion and closures
- `. as $x`, including destructuring `[$a, {b: $c, $d, (expr): $e}]` and alternatives `?//`
- assignments `=`, `|=`, `+=`, `-=`, `*=`, `/=`, `%=`, `//=`
- string interpolation `"\(e)"`, `@format` and `@format "text \(e)"`
- object construction including `{a}`, `{$x}`, `{"a b"}`, `{(e): v}`, keyword keys
- `$__loc__` and `#` comments

Not supported: modules (`import`/`include`), and I/O or environment (`input`, `inputs`, `$ENV`, `env`, `halt`, `halt_error`, `input_line_number`, `$__prog_args`). These fail at compile time with a message that says so.

## Builtins

Everything in jq 1.7.1's `builtins`, except the I/O ones listed above.

- **Paths:** `path`, `paths`, `leaf_paths`, `getpath`, `setpath`, `delpaths`, `del`, `pick`, `to_entries`, `from_entries`, `with_entries`, `tostream`, `fromstream`, `truncate_stream`
- **Arrays and objects:** `length`, `utf8bytelength`, `keys`, `keys_unsorted`, `values`, `has`, `in`, `inside`, `contains`, `map`, `map_values`, `select`, `empty`, `error`, `add`, `any`, `all`, `flatten`, `range/1,2,3`, `sort`, `sort_by`, `group_by`, `unique`, `unique_by`, `min`, `max`, `min_by`, `max_by`, `reverse`, `first`, `last`, `nth`, `limit`, `until`, `while`, `repeat`, `isempty`, `recurse`, `walk`, `transpose`, `combinations`, `bsearch`, `IN`, `INDEX`, `JOIN`, `splits`
- **Strings:** `tostring`, `tonumber`, `type`, `ascii_downcase`, `ascii_upcase`, `ltrimstr`, `rtrimstr`, `startswith`, `endswith`, `split/1,2`, `join`, `test`, `match`, `capture`, `scan`, `sub`, `gsub`, `explode`, `implode`, `indices`, `index`, `rindex`, `tojson`, `fromjson`, `@text`, `@json`, `@html`, `@uri`, `@csv`, `@tsv`, `@sh`, `@base64`, `@base64d`, `format`
- **Math:** `floor`, `ceil`, `round`, `fabs`, `sqrt`, `pow`, `log`, `exp`, and the rest of jq's libm set
- **Numbers:** `infinite`, `nan`, `isinfinite`, `isnan`, `isnormal`
- **Dates:** `now`, `mktime`, `gmtime`, `localtime`, `strftime`, `strflocaltime`, `strptime`, `todate`, `fromdate`, `todateiso8601`, `fromdateiso8601`
- **Other:** `builtins`, `debug` and `stderr` (identity, with no output), `input_filename` (null)

Added from jq 1.6 and 1.8: `leaf_paths`, `ascii`, `add(f)`, `trim`, `ltrim`, `rtrim`, `trimstr`, `toarray`, `toboolean`, `skip`, `abs`, `@base32`, `@base32d`.

## Differences from jq 1.7.1

- **Numbers are doubles.** jq 1.7 prints number literals as written (`1.000`, `1E+2`); vestal prints the canonical form (`1`, `100`). Computed values print the same way in both, including `1e+17`, `1e-05` and `0.30000000000000004`. A computed `-0` prints as `0` in both.
- **String offsets are code points.** `index`, `rindex` and `indices` on strings return code point offsets. jq 1.7.1 returns byte offsets for non-ASCII text, which do not work with slicing. Global empty regex matches also step by character; jq 1.7.1 steps inside multi-byte characters.
- **Regexes use NSRegularExpression (ICU), not Oniguruma.** Common syntax is the same: classes, quantifiers, anchors, lookaround, `\d \w \s \b`, named groups `(?<name>...)` (including names with `_`, which are rewritten internally), `\k<name>`, and inline flags. The flags map as follows: `g` global, `i` case-insensitive, `x` extended, `n` skip empty matches, `p` makes `.` match newlines, and `s` and `l` are accepted and do nothing. Known differences: `$` also matches before a final newline, Oniguruma-only syntax such as `\h` and `(?~...)` is not supported, and the text of regex compile errors differs.
- **`strptime`** is vestal's own C-locale parser. It supports `%Y %m %d %e %H %M %S %y %C %j %b %B %h %a %A %p %I %z %Z %s %T %D %F %R %r %c %x %X %n %t %%`. Results are normalized through `timegm` (`%z` offsets are converted to UTC, as jq does on macOS). A format without a date gives 1900-01-01, where jq gives day 0. `strftime` is also locale-independent: `%Z` is `UTC`, and names are English.
- **Error text** matches jq's for runtime errors, including the truncated value dumps. The exceptions are JSON parse errors from `fromjson`/`tonumber` and regex compile errors, which are worded similarly but not identically. Syntax and compile errors are vestal's own, with a position and a suggestion.
- **Not reproduced:** jq's literal-number preservation, locale-dependent `strftime` output, and platform-specific `strptime` quirks.

## Known costs and limits

- `add`, `join`, `=`, `|=` and the other update operators build their result in place, so they are linear, as in jq. A `reduce` whose update copies its accumulator is quadratic, because the evaluator cannot hand the accumulator over: `reduce .[] as $x ({}; .[$x.k] = $x)` over 2,000 items takes about 60 ms in a release build. For large inputs, prefer `map`, `group_by` and `from_entries`.
- One regex match cannot be interrupted, since ICU has no time limit in NSRegularExpression. A catastrophic pattern such as `^(a+)+$` on a long string is not stopped by `maxDuration`; `maxRegexSubject` and `maxRegexPattern` only bound the damage. `uregex_setTimeLimit` is not reachable from Foundation without C, so no time limit is set.
- Printing, comparing and freeing a value recurse once per nesting level. Values built by expressions are capped at 512 levels, and `JQValue.parse` at 256 by default. Values built in Swift (`JQValue(foundation:)`, `JQValue(_: AnyJSON)`) are not checked, so keep them shallow.
- On Linux, `JQValue(foundation:)` detects booleans by `NSNumber.objCType`, so an `NSNumber` made from an `Int8` reads as a boolean. JSONSerialization never produces those.

## Legacy paths

`JQExpression.normalizeLegacyPath(_:)` turns a dot path string into jq. `rates.BRL` becomes `.rates.BRL`, `BRL-X.rate` becomes `."BRL-X".rate`, `[0].name` becomes `.[0].name`, and a path already starting with `.` is returned unchanged. A bare word is a field: `length` becomes `.length`. `JSONPath` itself is unchanged.

## Fixtures

`scripts/gen-expr-fixtures.py --jq <jq 1.7.1> --jq18 <jq 1.8.x>` regenerates `expr-cases.json` from `expr-cases.txt`, running jq with `TZ=UTC LC_ALL=C`. jq 1.7.1 is `nix build 'github:nixos/nixpkgs/nixos-24.05#jq.bin'`.
