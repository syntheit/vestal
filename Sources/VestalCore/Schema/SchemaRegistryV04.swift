import Foundation

// MARK: - Schema registry: the widget model
//
// The engine's own widget types (6 containers, 8 primitives),
// the fields every widget takes, the shapes they use, and the
// built-in templates as types (their parameters, from TemplateRegistry). The
// legacy widget types in `widgetTypes` stay as they are (Config decodes them);
// `allWidgetTypes` is every type a config may name.

extension SchemaRegistry {
    // MARK: Common fields

    /// Fields every widget takes besides `type`, template instances included.
    public static let commonWidgetKeys: [SchemaKey] = [
        SchemaKey("id", .string, since: "0.4", examples: [.string("cpu")],
                  "A stable id segment for the node. Default: the widget key or its index."),
        SchemaKey("source", .any, since: "0.4", examples: [.string("system"), .object(["type": .string("file"), "path": .string("~/notes.md"), "parse": .string("lines")])],
                  "The data for this subtree: a source name, or a source definition (an inline source). Sets . and $data."),
        SchemaKey("input", .string, kind: .expr, since: "0.4", examples: [.string(".current_condition[0]")],
                  "Re-roots . for this subtree."),
        SchemaKey("vars", .map(.string), kind: .expr, since: "0.4", examples: [.object(["b": .string("find({casa: \"blue\"})")])],
                  "Binds $name for this subtree; a var may use the others it names."),
        SchemaKey("when", .any, kind: .expr, since: "0.4", examples: [.string(".battery != null")],
                  "Hidden when it yields false or null. A hidden widget takes no space."),
        SchemaKey("loading", .any, default: .string("hide"), since: "0.4", examples: [.string("show")],
                  "While this widget's own source has never produced data: hide, show (with . = null), or a widget to draw instead."),
        SchemaKey("style", .shape("style"), since: "0.4", examples: [.object(["size": .int(12), "color": .string("subtle")])],
                  "Text style and color, inherited by everything under it."),
        SchemaKey("width", .any, default: .string("fit"), since: "0.4", examples: [.int(60), .string("fill")], computed: true,
                  "Points, fill (the space the parent offers) or fit."),
        SchemaKey("height", .any, default: .string("fit"), since: "0.4", examples: [.int(24), .string("fill")], computed: true,
                  "Points, fill or fit."),
        SchemaKey("minWidth", .number, since: "0.4", examples: [.int(40)], computed: true, "The least width."),
        SchemaKey("maxWidth", .number, since: "0.4", examples: [.int(400)], computed: true, "The largest width."),
        SchemaKey("padding", .any, default: .int(0), since: "0.4", examples: [.int(8), .array([.int(2), .int(6), .int(2), .int(6)])],
                  computed: true, "Inside the frame: a number, or [top, right, bottom, left]."),
        SchemaKey("background", .any, since: "0.4", examples: [.string("track"), .string("accent@0.15")], computed: true,
                  "A color painted behind the padded frame."),
        SchemaKey("border", .any, since: "0.4", examples: [.object(["color": .string("accent@0.6"), "width": .int(1)])],
                  "An outline around the padded frame, following the radius: {color (default dim), width (default 1)}."),
        SchemaKey("radius", .number, default: .int(0), since: "0.4", examples: [.int(4)], computed: true,
                  "Corner radius of the background and the border."),
        SchemaKey("opacity", .number, default: .int(1), since: "0.4", examples: [.double(0.6)], computed: true, "0 to 1."),
        SchemaKey("clip", .boolean, default: .bool(false), since: "0.4", examples: [.bool(true)], computed: true,
                  "Clip children to the frame."),
        SchemaKey("spaceBefore", .number, since: "0.4", examples: [.int(24)], computed: true,
                  "Space before this child in a stack or row, instead of the parent's gap. Ignored on the first visible child."),
        SchemaKey("alignSelf", .oneOf(["start", "center", "end", "stretch"]), since: "0.4", examples: [.string("center")],
                  computed: true, "Cross-axis alignment of this child. Default: the parent's align."),
        SchemaKey("span", .integer(minimum: 1), default: .int(1), since: "0.4", examples: [.int(2)], computed: true,
                  "Grid columns this child takes."),
        SchemaKey("action", .any, since: "0.4", examples: [.object(["open": .string("{{ .url }}")])],
                  "An action or a list of actions, run on click and on key: run, open, copy, refresh, view, popup, close, media, audio, timer, toggleTodo, hide."),
        SchemaKey("key", .any, since: "0.4", examples: [.string("g"), .string("auto")], computed: true,
                  "A key that runs action; auto takes the first free letter of keyHint."),
        SchemaKey("keyHint", .string, kind: .text, since: "0.4", examples: [.string("{{ .name }}")],
                  "Letters auto tries, in order. Default: the widget's first text."),
        SchemaKey("alt", .string, kind: .text, since: "0.4", examples: [.string("CPU {{ .cpu.percent }}%")],
                  "Plain-text rendition for text-only UIs and accessibility."),
    ]

    private static func key(_ name: String, _ type: SchemaType, kind: SchemaKind = .literal, default defaultValue: AnyJSON? = nil,
                            required: Bool = false, _ example: AnyJSON, computed: Bool = false, _ description: String) -> SchemaKey {
        SchemaKey(name, type, kind: kind, default: defaultValue, required: required, since: "0.4",
                  examples: [example], computed: computed, description)
    }

    private static let colorKey = { (name: String, fallback: String?, description: String) -> SchemaKey in
        key(name, .any, default: fallback.map(AnyJSON.string), .string("accent"), computed: true, description)
    }

    private static let aligns: [String] = ["start", "center", "end", "stretch"]

    private static func containerKeys(gap: Int, align: String, row: Bool) -> [SchemaKey] {
        [
            key("children", .list(.widget), default: .array([]), .array([.string("clock")]), "Widgets or widget keys."),
            key("gap", .number, default: .int(gap), .int(12), computed: true, "Space between visible children."),
            key("align", .oneOf(aligns + (row ? ["baseline"] : [])), default: .string(align), .string("center"), computed: true,
                "Cross-axis alignment" + (row ? "; baseline lines up the first text baselines." : ".")),
            key("justify", .oneOf(["start", "center", "end", "between"]), default: .string("start"), .string("between"), computed: true,
                "Main-axis distribution when the container is larger than its content."),
        ]
    }

    private static let listKeys: [SchemaKey] = [
        key("items", .any, kind: .expr, required: true, .string(".items"),
            "The array to iterate over: a jq expression (all outputs, or its single array), or a JSON array (static data)."),
        key("filter", .string, kind: .expr, .string(".isDraft | not"), "Per item (. = item); keeps it when true."),
        key("sortBy", .string, kind: .expr, .string(".updatedAt | to_epoch"), "Per item; sorts ascending, stably."),
        key("reverse", .boolean, default: .bool(false), .bool(true), computed: true, "After sorting."),
        key("limit", .integer(minimum: 0), .int(5), computed: true, "At most this many rows."),
        key("rowId", .string, kind: .expr, .string(".url"), "A stable identity per row. Default: the index."),
        key("empty", .any, kind: .text, .string("Nothing to review"), "Text or a widget shown when there are no rows. Default: hide."),
    ]

    private static func styleKey(_ name: String, _ description: String) -> SchemaKey {
        key(name, .shape("style"), .object(["size": .int(10), "color": .string("dim")]), description)
    }

    // MARK: Types

    /// The engine's own widget types.
    public static let v04WidgetTypes: [SchemaEntityType] = [
        SchemaEntityType("stack", since: "0.4", "Children top to bottom.", keys: containerKeys(gap: 8, align: "start", row: false)),
        SchemaEntityType("row", since: "0.4", "Children left to right.", keys: containerKeys(gap: 8, align: "center", row: true)),
        SchemaEntityType("grid", since: "0.4", "Children row by row in aligned columns.", keys: [
            key("children", .list(.widget), default: .array([]), .array([.string("cpu")]), "Widgets, placed row by row. A child may set span."),
            key("columns", .any, default: .int(2), .int(3), computed: true,
                "A count of equal fill columns, or a list of {width: number | fill | fit, align}."),
            key("gap", .number, default: .int(12), .int(16), computed: true, "Between columns."),
            key("rowGap", .number, default: .int(12), .int(8), computed: true, "Between rows. Default: gap."),
        ]),
        SchemaEntityType("list", since: "0.4", "An array as rows, with filter, sort and limit.", keys: listKeys + [
            key("row", .widget, required: true, .object(["type": .string("text"), "text": .string("{{ .title }}")]),
                "One row: . is the item; $item, $index and $parent are bound."),
            key("direction", .oneOf(["column", "row", "grid"]), default: .string("column"), .string("row"), computed: true, "How rows are laid out."),
            key("columns", .integer(minimum: 1), default: .int(2), .int(3), computed: true, "For direction grid."),
            key("gap", .number, default: .int(8), .int(6), computed: true, "Between rows."),
            key("align", .oneOf(aligns), default: .string("start"), .string("center"), computed: true, "Cross-axis alignment of rows."),
        ]),
        SchemaEntityType("table", since: "0.4", "A list whose columns line up across rows.", keys: listKeys + [
            key("columns", .list(.shape("tableColumn")), required: true,
                .array([.object(["header": .string("Mount"), "text": .string("{{ .mount }}")])]), "The columns."),
            key("header", .boolean, default: .bool(true), .bool(false), computed: true, "Show a header row."),
            key("gap", .number, default: .int(12), .int(16), computed: true, "Between columns."),
            key("rowGap", .number, default: .int(6), .int(8), computed: true, "Between rows."),
            key("rowAction", .any, .object(["open": .string("{{ .url }}")]), "An action per row (. = the item)."),
        ]),
        SchemaEntityType("switch", since: "0.4", "One child picked by a value.", keys: [
            key("on", .string, kind: .expr, required: true, .string(".state"), "Evaluated, then tostring."),
            key("cases", .map(.widget), required: true, .object(["playing": .object(["type": .string("icon"), "name": .string("play")])]),
                "Case value → widget."),
            key("default", .widget, .object(["type": .string("text"), "text": .string("off")]),
                "Used when no case matches; if absent, nothing is drawn."),
        ]),
        SchemaEntityType("text", since: "0.4", "Text, with an optional leading icon and a formatted value.", keys: [
            key("text", .string, kind: .text, default: .string(""), .string("CPU {{ .cpu.percent | round }}%"), "What to show."),
            key("value", .string, kind: .expr, .string(".disks[0].free"), "Instead of text: a value run through format, between prefix and suffix."),
            key("format", .string, .string("bytes"), computed: true,
                "int, number, fixed:N, percent, percent:N, thousands, compact, bytes, rate, duration, uptime, relative, startsIn, "
                + "time:<pattern>, localized:<skeleton>."),
            key("prefix", .string, kind: .text, default: .string(""), .string("$"), "Before a formatted value."),
            key("suffix", .string, kind: .text, default: .string(""), .string(" free"), "After a formatted value."),
            key("placeholder", .string, kind: .text, default: .string("–"), .string("n/a"), "Shown when value is null."),
            key("icon", .string, .string("hard-drives"), computed: true, "A leading icon (Phosphor name)."),
            colorKey("iconColor", nil, "The icon's color. Default: the text's."),
            key("iconSize", .number, .int(10), computed: true, "The icon's size. Default: 0.8 × the text size."),
            key("iconWeight", .oneOf(["regular", "fill"]), default: .string("regular"), .string("fill"), computed: true, "The icon's weight."),
            key("gap", .number, default: .int(5), .int(8), computed: true, "Between the icon and the text."),
            key("lines", .integer(minimum: 1), .int(1), computed: true, "Line limit; overflow is truncated with …. Default: unlimited."),
            key("align", .oneOf(["start", "center", "end"]), default: .string("start"), .string("end"), computed: true, "Text alignment in its frame."),
            key("size", .any, .int(12), computed: true, "Shorthand for style.size."),
            key("weight", .any, .string("semibold"), computed: true, "Shorthand for style.weight."),
            colorKey("color", nil, "Shorthand for style.color."),
        ]),
        SchemaEntityType("icon", since: "0.4", "A glyph from the bundled Phosphor set.", keys: [
            key("name", .string, required: true, .string("cpu"), computed: true,
                "A Phosphor icon name (vestal icons searches them); sf:<symbol> only under platform.macos."),
            key("weight", .oneOf(["regular", "fill"]), default: .string("regular"), .string("fill"), computed: true, "regular or fill."),
            key("size", .number, default: .int(13), .int(10), computed: true, "Points."),
            colorKey("color", nil, "Default: the inherited text color."),
        ]),
        SchemaEntityType("progress", since: "0.4", "A horizontal bar with an optional label, value text and overlay.", keys: [
            key("value", .any, kind: .expr, required: true, .string(".memory.percent"), "The value."),
            key("max", .any, kind: .expr, default: .int(100), .int(100), "The top of the scale: an expression or a number."),
            key("min", .any, kind: .expr, default: .int(0), .int(0), "The bottom of the scale: an expression or a number."),
            key("overlay", .any, kind: .expr, .string(".memory.pressure"), "A second value on the same scale."),
            key("overlayPosition", .oneOf(["above", "below"]), default: .string("above"), .string("below"), computed: true,
                "above: over the fill. below: under it."),
            key("start", .any, kind: .expr, .int(10), "Where the fill begins, on the same scale: the fill covers start to value (a range bar). Default: min."),
            key("tick", .any, kind: .expr, .int(57), "A thin mark at this value on the same scale, such as where usage would be at an even pace."),
            colorKey("tickColor", "#ffffff8c", "The mark's color."),
            key("tickOverhang", .number, default: .int(0), .int(3), computed: true, "How far the tick reaches above and below the bar, in points."),
            key("gradient", .list(.any), .array([.string("cyan"), .string("orange")]),
                "Two or more colors the fill runs through, left to right across the fill (a range bar's low to high). Default: color."),
            key("label", .string, kind: .text, .string("RAM"), "Drawn before the bar."),
            key("labelWidth", .number, .int(24), computed: true, "The label's minimum width; it aligns to its end, and a wider label widens it."),
            key("text", .string, kind: .text, default: .string("{{ $value | round }}%"), .string(""), "Drawn after the bar; \"\" for none."),
            key("textWidth", .number, .int(30), computed: true, "The text's minimum width."),
            colorKey("color", "accent", "The fill's color."),
            colorKey("trackColor", nil, "Default: color at 15%."),
            colorKey("overlayColor", "#ffffff33", "The overlay's color."),
            styleKey("labelStyle", "Default: size 9 semibold dim."),
            styleKey("textStyle", "Default: size 10 mono subtle."),
            key("gap", .number, default: .int(4), .int(6), computed: true, "Between the label, the bar and the text."),
        ]),
        SchemaEntityType("gauge", since: "0.4", "A ring with center text.", keys: [
            key("value", .any, kind: .expr, required: true, .string(".cpu.percent"), "The value."),
            key("max", .any, kind: .expr, default: .int(100), .int(100), "The top of the scale."),
            key("min", .any, kind: .expr, default: .int(0), .int(0), "The bottom of the scale."),
            key("text", .string, kind: .text, default: .string("{{ $value | round }}"), .string("{{ $value | round }}%"), "Center text."),
            key("label", .string, kind: .text, .string("CPU"), "Under the ring."),
            key("size", .number, default: .int(64), .int(48), computed: true, "Diameter in points."),
            key("thickness", .number, default: .int(6), .int(4), computed: true, "The ring's thickness."),
            key("sweep", .number, default: .int(270), .int(360), computed: true, "Degrees of arc; the gap is centered at the bottom. 360 starts at the top."),
            colorKey("color", "accent", "The fill's color."),
            colorKey("trackColor", nil, "Default: color at 15%."),
            key("dot", .boolean, default: .bool(false), .bool(true), computed: true, "A dot on the end of the fill."),
            colorKey("dotColor", "text", "The dot's color."),
            key("ticks", .integer(minimum: 0, maximum: 120), default: .int(0), .int(24), computed: true,
                "Marks around the outside, evenly spaced; every fourth is longer. The ring moves inwards to fit them."),
            key("labels", .list(.string), .array([.string("00"), .string("06"), .string("12"), .string("18")]),
                "Up to four labels inside the ring at the quarters of the sweep, from its start."),
            key("center", .widget, .object(["type": .string("text"), "text": .string("{{ now | fmt_time(\"HH:mm\") }}")]),
                "A widget in the middle instead of text."),
            styleKey("textStyle", "Default: size 15 semibold mono text."),
            styleKey("labelStyle", "Default: size 10 semibold subtle."),
        ]),
        SchemaEntityType("sparkline", since: "0.4", "A line from an array or a history.", keys: [
            key("values", .string, kind: .expr, .string("$history.stats.cpu"), "An array of numbers."),
            key("value", .string, kind: .expr, .string(".ethereum.usd"), "Or: a value sampled into a history (with history)."),
            key("history", .shape("sparkHistory"), .object(["size": .int(288)]), "The history value is sampled into."),
            key("min", .any, kind: .expr, .int(0), "Fix the bottom of the scale. Default: the data's own."),
            key("max", .any, kind: .expr, .int(100), "Fix the top of the scale. Default: the data's own."),
            colorKey("color", "accent", "The line's color; may use $value (the last point)."),
            colorKey("fill", nil, "A color under the line."),
            key("strokeWidth", .number, default: .double(1.5), .int(2), computed: true, "The line's width."),
            key("dot", .boolean, default: .bool(false), .bool(true), computed: true, "A dot on the last point."),
            key("dotAt", .any, kind: .expr, .double(0.4), "A dot on the line at this fraction of its width, 0 to 1, instead of on the last point."),
            colorKey("dotColor", nil, "The dotAt dot's color. Default: the line's."),
        ]),
        SchemaEntityType("keyValue", since: "0.4", "Labeled values side by side.", keys: [
            key("items", .list(.shape("keyValueItem")), required: true,
                .array([.object(["label": .string("BRL"), "value": .string(".rates.BRL"), "format": .string("fixed:2")])]),
                "The values. An item whose source has no data, whose when is false or whose value is null is skipped."),
            key("gap", .number, default: .int(24), .int(16), computed: true, "Between items."),
            key("align", .oneOf(["start", "center", "end"]), default: .string("center"), .string("start"), computed: true,
                "Of label and value within an item."),
            styleKey("labelStyle", "Default: size 10 semibold subtle."),
            styleKey("valueStyle", "Default: size 14 text."),
        ]),
        SchemaEntityType("divider", since: "0.4", "A rule.", keys: [
            key("axis", .oneOf(["h", "v"]), default: .string("h"), .string("v"), computed: true, "h fills the width; v fills the height."),
            key("thickness", .number, default: .double(0.5), .int(1), computed: true, "Points."),
            colorKey("color", "dim", "The rule's color."),
        ]),
        SchemaEntityType("spacer", since: "0.4", "Flexible space along the parent's axis (a fixed gap with width or height).", keys: [
            key("min", .number, default: .int(0), .int(8), computed: true, "The least space."),
        ]),
        SchemaEntityType("bars", since: "0.4", "A bar chart from an array of numbers or of {value, label, color}.", keys: [
            key("values", .any, kind: .expr, required: true, .string("[.hourly[].tempC | tonumber]"),
                "An array of numbers, or of objects {value, label?, color?}: an expression or a literal array."),
            key("orientation", .oneOf(["vertical", "horizontal"]), default: .string("vertical"), .string("horizontal"), computed: true,
                "vertical: columns, 160 by 48. horizontal: a row per bar with its label before and its value after."),
            key("max", .any, kind: .expr, .int(100), "The value of a full bar. Default: the largest value."),
            key("labels", .boolean, .bool(true), computed: true,
                "Draw the labels: under the columns (small, dim), or before the rows. Default: false for vertical, true for horizontal."),
            colorKey("color", "accent", "One color for every bar, or steps of each bar's value. A value's own color wins."),
            key("barWidth", .number, .int(8), computed: true,
                "Vertical: a column's width (default: the columns share the width). Horizontal: a bar's thickness (6)."),
            key("gap", .number, .int(4), computed: true, "Between columns (3) or rows (6)."),
            key("format", .string, .string("percent"), "Horizontal: a text format name for the value text. Default: the number, rounded."),
            key("labelWidth", .number, .int(80), computed: true, "Horizontal: the label column's width (default: the widest label)."),
            styleKey("labelStyle", "Default: size 9 dim (vertical) or size 10 subtle (horizontal)."),
            styleKey("valueStyle", "Horizontal. Default: size 10 mono subtle."),
            key("placeholder", .string, kind: .text, .string("n/a"), "Shown instead of the chart when values is null."),
        ]),
        SchemaEntityType("stackedBar", since: "0.4", "One bar split into colored segments.", keys: [
            key("segments", .any, kind: .expr, required: true, .string("[{value: .disks[0].used, label: \"Used\"}]"),
                "An array of {value, label?, color?}: an expression or a literal array."),
            key("total", .any, kind: .expr, .string(".disks[0].total"),
                "The whole bar. Default: the segments' sum; what they leave is drawn as the track."),
            key("legend", .boolean, default: .bool(false), .bool(true), computed: true,
                "A row of color dots and labels under the bar."),
            colorKey("color", nil, "A segment without its own color: this (steps of its value), else a cycle of palette colors."),
            colorKey("trackColor", "track", "The empty part of the bar."),
            key("radius", .number, .int(2), computed: true, "The bar's corner radius. Default: half its height."),
            styleKey("labelStyle", "The legend. Default: size 10 subtle."),
            key("placeholder", .string, kind: .text, .string("n/a"), "Shown instead of the bar when segments is null."),
        ]),
        SchemaEntityType("heatmap", since: "0.4", "A grid of cells colored by value.", keys: [
            key("values", .any, kind: .expr, required: true, .string("$history.stats.cpu"),
                "An array of numbers; null is an empty cell. An expression or a literal array."),
            key("rows", .integer(minimum: 1, maximum: 366), default: .int(7), .int(7), "Cells down a column (direction columns) or rows."),
            key("direction", .oneOf(["columns", "rows"]), default: .string("columns"), .string("rows"), computed: true,
                "columns: fill down each column, then the next. rows: fill across each row."),
            key("cell", .number, default: .int(8), .int(10), computed: true, "A cell's size in points."),
            key("gap", .number, default: .int(2), .int(3), computed: true, "Between cells."),
            key("radius", .number, default: .int(2), .int(3), computed: true, "A cell's corner radius."),
            key("scale", .list(.string), default: .array([.string("accent@0.2"), .string("accent")]),
                .array([.string("#161b22"), .string("good")]),
                "Two colors, low and high, mixed by where a value is between min and max."),
            key("steps", .list(.list(.any)), .array([.array([.int(0), .string("track")]), .array([.int(5), .string("good")])]),
                "Instead of scale: [threshold, color] pairs; a value takes the last stop at or below it."),
            key("min", .any, kind: .expr, .int(0), "The value at the low end of scale. Default: the smallest."),
            key("max", .any, kind: .expr, .int(10), "The value at the high end of scale. Default: the largest."),
            colorKey("trackColor", "track", "An empty (null) cell."),
            key("placeholder", .string, kind: .text, .string("n/a"), "Shown instead of the grid when values is null."),
        ]),
        SchemaEntityType("timeline", since: "0.4", "A time axis with items as bars and markers.", keys: [
            key("from", .any, kind: .expr, .string("now"),
                "The left edge: epoch seconds or ISO 8601 (an expression, or the time itself). Default: the start of today."),
            key("to", .any, kind: .expr, .string("now + 86400"), "The right edge. Default: a day after from."),
            key("items", .any, kind: .expr, .string("[.events[] | {start, end, label: .title}]"),
                "An array of {start, end?, label?, color?}; no end is a marker. An expression or a literal array."),
            key("now", .boolean, default: .bool(true), .bool(false), computed: true, "A line at the current time."),
            colorKey("nowColor", "accent", "The current-time line."),
            colorKey("color", "accent", "An item without its own color."),
            key("placeholder", .string, kind: .text, .string("n/a"), "Shown instead of the axis when items is null."),
        ]),
        SchemaEntityType("image", since: "0.4", "A picture from a file or an http(s) URL.", keys: [
            key("src", .string, kind: .text, required: true, .string("~/Pictures/me.png"),
                "A file path (~ expanded) or an http(s) URL; {{ }} holes and {\"expr\": …} compute it."),
            key("fit", .oneOf(["cover", "contain"]), default: .string("cover"), .string("contain"), computed: true,
                "cover fills the frame and crops; contain shows the whole picture."),
            key("radius", .number, default: .int(6), .int(24), computed: true, "The picture's corner radius."),
        ]),
        SchemaEntityType("analog", since: "0.4", "A round clock the UI draws and runs itself.", keys: [
            key("size", .number, .int(236), computed: true, "The face's diameter. Default: 236 without ticks, 260 with."),
            key("ticks", .oneOf(["none", "hours", "minutes", "dots"]), default: .string("hours"), .string("minutes"), computed: true,
                "none: a hairline ring and a dot at twelve, short hands. hours: twelve marks. minutes: sixty, heavier at the hours. dots: twelve dots and short plain hands, for a dial of about 64."),
            key("seconds", .any, default: .bool(false), .string("sweep"), computed: true,
                "false: no seconds hand. true or \"step\": it moves once a second. \"sweep\": it moves every frame while the dashboard is shown."),
            key("dateWindow", .boolean, default: .bool(false), .bool(true), computed: true, "A window with the day of the month at three o'clock."),
            key("numerals", .boolean, default: .bool(false), .bool(true), computed: true, "The numerals 1 to 12."),
            key("zone", .string, kind: .text, .string("Asia/Tokyo"), "An IANA time zone. Default: the system's."),
            colorKey("color", "text", "The hands, ticks and numerals."),
            colorKey("faceColor", nil, "The face's fill. Default: text at 3.5% without ticks, bg at 32% with."),
            colorKey("nightFaceColor", nil, "The face's fill while it is night in zone (19:00 to 07:00). Default: faceColor always."),
            colorKey("secondsColor", "bad", "The seconds hand."),
            colorKey("pivotColor", nil, "The pivot. Default: accent, or the seconds hand's color with one."),
        ]),
        SchemaEntityType("matrix", since: "0.4", "A dot matrix or seven-segment display the UI draws, unlit cells faintly visible.", keys: [
            key("text", .string, kind: .text, required: true, .string("{{ now | fmt_time(\"HH:mm:ss\") }}"), "Digits and :; anything else is a blank digit."),
            key("cells", .oneOf(["dots", "segments"]), default: .string("dots"), .string("segments"), computed: true,
                "dots: a 5 by 7 grid per digit. segments: seven-segment digits."),
            key("size", .number, default: .int(84), .int(60), computed: true, "The height of a dot matrix in points (a segment digit is 86/84 of it)."),
            colorKey("color", "cyan", "The lit cells."),
            colorKey("offColor", nil, "The unlit cells. Default: text at 6.5%."),
        ]),
        SchemaEntityType("moon", since: "0.4", "The moon's phase drawn as the lit part of a disc, on the side the phase says.", keys: [
            key("phase", .any, kind: .expr, required: true, .string(".moon.phase"), "0 (new) to 1; 0.5 is full. Below 0.5 the right side is lit."),
            key("size", .number, default: .int(22), .int(28), computed: true, "The square's side."),
            colorKey("color", "#e8e4d4ff", "The lit part."),
            colorKey("trackColor", nil, "The rest of the disc. Default: text at 8%."),
        ]),
        SchemaEntityType("flip", since: "0.4", "Split-flap tiles: one per character, changed ones fold over.", keys: [
            key("text", .string, kind: .text, required: true, .string("{{ now | fmt_time(\"HH:mm\") }}"),
                "The big tiles: digits, : as a colon, a space as a gap."),
            key("small", .string, kind: .text, .string("{{ now | fmt_time(\"ss\") }}"), "Small tiles after the big ones (seconds)."),
            key("size", .number, default: .int(90), .int(60), computed: true, "The big tiles' font size; a tile is 0.89 by 1.27 of it."),
            key("smallSize", .number, .int(27), computed: true, "The small tiles' font size. Default: 4/9 of size."),
            colorKey("color", "text", "The characters."),
            colorKey("tileColor", nil, "The tile. Default: the palette's bg, lightened."),
            key("animate", .boolean, default: .bool(true), .bool(false), computed: true,
                "Fold a tile over when its character changes (never with reduced motion)."),
        ]),
    ]

    /// Built-in widget templates that aren't legacy types (section, stat,
    /// badge, claudeItem, hostDetail), their keys from the parameters.
    public static var templateWidgetTypes: [SchemaEntityType] {
        let v03 = Set(widgetTypes.map(\.name))
        return TemplateRegistry.standard.builtins.values
            .filter { !$0.isSource && !v03.contains($0.name) }
            .sorted { $0.name < $1.name }
            .map { SchemaEntityType($0.name, since: "0.4", $0.description ?? "A built-in template.",
                                    keys: templateKeys($0)) }
    }

    /// Source templates (foyer) as source types.
    public static var templateSourceTypes: [SchemaEntityType] {
        TemplateRegistry.standard.builtins.values
            .filter(\.isSource)
            .sorted { $0.name < $1.name }
            .map { template in
                let common = sourceTypes.first!.keys.filter { Expander.commonSourceKeys.contains($0.name) }
                return SchemaEntityType(template.name, since: "0.4", template.description ?? "A source template.",
                                        keys: templateKeys(template) + common.map { var k = $0; k.defaultValue = nil; return k })
            }
    }

    /// A template's parameters as schema keys.
    public static func templateKeys(_ template: TemplateDefinition) -> [SchemaKey] {
        template.params.keys.sorted().map { name in
            let param = template.params[name]!
            let type: SchemaType
            var kind = SchemaKind.literal
            switch param.type {
            case "string": type = .string
            case "number": type = .number
            case "integer": type = .integer(minimum: nil)
            case "boolean": type = .boolean
            case "array": type = .list(.any)
            case "duration": type = .duration
            case "icon": type = .string
            case "expr": type = .string; kind = .expr
            case "text": type = .string; kind = .text
            case "widget": type = .widget
            case "widgets": type = .list(.widget)
            default: type = .any
            }
            let example: AnyJSON
            if let value = param.defaultValue, value != .string(""), value != .array([]) {
                example = value
            } else {
                switch param.type {
                case "expr": example = .string(".value")
                case "text", "string", "icon": example = .string(name == "icon" ? "star" : "x")
                case "number", "integer": example = .int(1)
                case "boolean": example = .bool(true)
                case "array", "widgets": example = .array([])
                case "object": example = .object([:])
                default: example = .string("x")
                }
            }
            return SchemaKey(name, type, kind: kind, default: param.defaultValue, required: param.required, since: "0.4",
                             examples: [example],
                             param.description ?? "The \(name) parameter (\(param.type)).")
        }
    }

    /// The legacy widget types as the schema and check-config see them in
    /// Their keys plus the template's extra parameters.
    public static var presetWidgetTypes: [SchemaEntityType] {
        widgetTypes.map { type in
            var type = type
            if let template = TemplateRegistry.standard.lookup(type.name) {
                let known = Set(type.keyNames)
                type.keys += templateKeys(template).filter { !known.contains($0.name) }
            }
            return type
        }
    }

    /// Every widget type a config may name, built in: legacy presets, the
    /// engine's own types and the other built-in templates.
    public static var allWidgetTypes: [SchemaEntityType] {
        presetWidgetTypes + v04WidgetTypes + templateWidgetTypes
    }

    /// Every source type, source templates included.
    public static var allSourceTypes: [SchemaEntityType] {
        sourceTypes + templateSourceTypes
    }

    /// A widget type's keys besides `type`, common fields included.
    public static func widgetKeys(_ type: SchemaEntityType) -> [SchemaKey] {
        let own = Set(type.keyNames)
        return type.keys + commonWidgetKeys.filter { !own.contains($0.name) }
    }

    // MARK: Shapes

    static let v04Shapes: [SchemaShape] = [
        SchemaShape("style", "Text style, inherited by everything under the widget. Fields may be {\"expr\": ...}.", keys: [
            key("size", .any, default: .string("base"), .int(12), computed: true,
                "Points, or xs 10, sm 11, md 12, base 13, lg 14, xl 18, 2xl 24, 3xl 36, display 56."),
            key("weight", .any, default: .string("regular"), .string("semibold"), computed: true,
                "ultralight, thin, light, regular, medium, semibold, bold, heavy, black, or 100–900."),
            key("font", .string, default: .string("sans"), .string("mono"), computed: true,
                "A font role (display, sans, mono, rounded) or a family name. A comma-separated list takes the first usable "
                + "entry: display counts when the theme sets that role, so \"display, Inter Tight\" is the theme's display "
                + "font, else Inter Tight."),
            colorKey("color", "text", "The text color."),
            key("tracking", .number, default: .int(0), .double(1.5), computed: true, "Letter spacing in points."),
            key("case", .oneOf(["upper", "lower", "none"]), default: .string("none"), .string("upper"), computed: true, "Case transform."),
            key("emphasis", .oneOf(["strong", "muted", "faint"]), .string("muted"), computed: true,
                "strong: weight +200 and text color; muted: subtle; faint: dim."),
            key("scale", .number, default: .int(1), .double(1.2), computed: true, "Multiplies sizes in this subtree."),
        ]),
        SchemaShape("tableColumn", "A table column.", keys: [
            key("header", .string, kind: .text, .string("Mount"), "The header text."),
            key("text", .string, kind: .text, .string("{{ .mount }}"), "The cell text."),
            key("value", .string, kind: .expr, .string(".percent"), "Instead of text: a value run through format."),
            key("format", .string, .string("percent"), "A text format name."),
            key("width", .any, .int(120), "Points, fill or fit."),
            key("fill", .boolean, .bool(true), "Same as width fill."),
            key("align", .oneOf(["start", "center", "end"]), .string("end"), "Cell alignment."),
            key("style", .shape("style"), .object(["font": .string("mono")]), "The cells' style."),
            colorKey("color", nil, "The cells' color; may use $value."),
        ]),
        SchemaShape("keyValueItem", "A keyValue item.", keys: [
            key("label", .string, kind: .text, required: true, .string("BRL"), "Shown above the value."),
            key("value", .string, kind: .expr, .string(".rates.BRL"), "The value."),
            key("format", .string, .string("fixed:2"), "A text format name."),
            key("text", .string, kind: .text, .string("{{ $q.compra | fmt_int }}"), "Overrides value and format."),
            colorKey("color", nil, "The value's color."),
            key("source", .string, .string("rates"), "A source for this item."),
            key("vars", .map(.string), kind: .expr, .object(["q": .string("find({casa: \"blue\"})")]), "Bindings for this item."),
            key("when", .string, kind: .expr, .string("$q != null"), "Skips the item when false or null."),
            key("action", .any, .object(["copy": .string("{{ .rates.BRL }}")]), "An action on click."),
            key("key", .string, .string("b"), "A key that runs action."),
        ]),
        SchemaShape("sparkHistory", "A sparkline's own history on its source.", keys: [
            key("size", .integer(minimum: 1, maximum: HistorySpec.maxSize), default: .int(HistorySpec.defaultSize), .int(288), "Samples kept."),
            key("every", .duration, .string("5m"), "The least time between samples. Default: the source's refresh."),
        ]),
        SchemaShape("palette", "A user palette.", keys: [
            key("extends", .string, default: .string("tokyo-night"), .string("tokyo-night"), "The palette it builds on."),
            key("colors", .map(.string), .object(["accent": .string("#ff9e64")]), "Colors added or overridden."),
        ]),
        SchemaShape("fonts", "A font family per role; null means the typeface's family, else the platform default.", keys: [
            key("display", .string, .string("Instrument Serif"), "The family for clocks and big numbers."),
            key("sans", .string, .string("Inter"), "The sans family."),
            key("mono", .string, .string("JetBrains Mono"), "The monospaced family."),
            key("rounded", .string, .string("SF Pro Rounded"), "The rounded family."),
        ]),
        SchemaShape("template", "A template: parameters and a widget or source body.", keys: [
            key("description", .string, .string("A labeled percentage bar"), "Shown by vestal docs and in the schema."),
            key("params", .map(.shape("templateParam")), .object(["label": .object(["type": .string("text"), "required": .bool(true)])]),
                "Name → parameter."),
            key("widget", .any, .object(["type": .string("progress"), "value": .object(["param": .string("value")])]),
                "The widget body; {\"param\": \"name\"} marks where a parameter goes."),
            key("source", .any, .object(["type": .string("http"), "url": .string("{{ $url }}/api")]),
                "The source body (a source template)."),
            key("override", .boolean, .bool(true), "Replace the built-in template of this name."),
        ]),
        SchemaShape("templateParam", "A template parameter.", keys: [
            key("type", .oneOf(TemplateParam.types.sorted()), default: .string("any"), .string("expr"),
                "string, number, integer, boolean, array, object, any, duration, color, icon, source (data, also bound as $name) "
                + "or expr, text, widget, widgets (code, substituted only)."),
            key("default", .any, .int(70), "Used when the instance doesn't set it."),
            key("required", .boolean, default: .bool(false), .bool(true), "The instance must set it."),
            key("description", .string, .string("0-100"), "Shown by vestal docs."),
            key("enum", .list(.any), .array([.string("sm"), .string("md")]), "The values allowed."),
        ]),
    ]
}
