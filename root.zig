//! XML: the `xml` adapter, writing whole XML files from a value tree.

const std = @import("std");
const kosm = @import("kosm");

/// Writes `.xml` files through `output.generate`, and with `.lang = "xml"` any XML file
/// (fontconfig's `.conf`). The root value is a table holding one entry, the root element,
/// optionally after `!DOCTYPE`-style declarations. Inside an element's table, a key starting
/// with `@` is an attribute, a list repeats its element once per item, and any other value is
/// the element's text. It cannot edit files yet.
pub const adapter: kosm.Adapter = .{
    .name = "xml",
    .extensions = &.{".xml"},
    .default_format = .{ .boolean = .true_false },
    .serialize = serialize,
};

/// Spaces per nesting level.
const indent_width = 2;

/// Deepest element nesting `serialize` writes.
const max_depth = 64;

fn serialize(writer: *std.Io.Writer, root: kosm.Value, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    if (root != .table) return context.unsupported("an XML file is a table holding its root element, not a {s}", .{@tagName(root)});
    try writer.writeAll("<?xml version=\"1.0\"?>\n");
    var root_element: ?kosm.Value.Entry = null;
    for (root.table) |entry| {
        if (std.mem.startsWith(u8, entry.key, "!")) {
            if (root_element != null) return context.unsupported("declaration '{s}' comes after the root element; put it first", .{entry.key});
            try writeDeclaration(writer, entry, context);
        } else {
            if (root_element) |first| return context.unsupported("an XML file has one root element, but '{s}' and '{s}' are both at the top", .{ first.key, entry.key });
            if (entry.value == .list) return context.unsupported("root element '{s}' is a list; an XML file has one root element", .{entry.key});
            root_element = entry;
        }
    }
    const element = root_element orelse return context.unsupported("the file has no root element", .{});
    try writeElement(writer, element.key, element.value, 0, context);
}

/// `!DOCTYPE` with `.raw("fontconfig SYSTEM \"urn:fontconfig:fonts.dtd\"")` writes
/// `<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">`.
fn writeDeclaration(writer: *std.Io.Writer, entry: kosm.Value.Entry, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    try checkName(entry.key[1..], context);
    const text = switch (entry.value) {
        .raw, .string => |text| text,
        else => return context.unsupported("declaration '{s}' must be text, not a {s}", .{ entry.key, @tagName(entry.value) }),
    };
    if (std.mem.indexOfScalar(u8, text, '>') != null) return context.unsupported("declaration '{s}' contains '>'", .{entry.key});
    try writer.print("<{s} {s}>\n", .{ entry.key, text });
}

/// One element, or for a list one per item, on lines of their own.
fn writeElement(writer: *std.Io.Writer, name: []const u8, value: kosm.Value, depth: usize, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    if (depth == max_depth) return context.unsupported("elements nest deeper than {d} levels", .{max_depth});
    try checkName(name, context);
    if (value == .list) {
        for (value.list) |item| {
            if (item == .list) return context.unsupported("element '{s}' is a list of lists; wrap the inner lists in elements", .{name});
            try writeElement(writer, name, item, depth, context);
        }
        return;
    }
    try writer.splatByteAll(' ', depth * indent_width);
    try writer.print("<{s}", .{name});
    const entries = switch (value) {
        .table => |entries| entries,
        else => {
            try writer.writeByte('>');
            try writeText(writer, value, name, context);
            return writer.print("</{s}>\n", .{name});
        },
    };
    var has_children = false;
    for (entries) |entry| {
        if (!std.mem.startsWith(u8, entry.key, "@")) {
            has_children = true;
            continue;
        }
        try checkName(entry.key[1..], context);
        try writer.print(" {s}=\"", .{entry.key[1..]});
        try writeText(writer, entry.value, entry.key, context);
        try writer.writeByte('"');
    }
    if (!has_children) return writer.writeAll("/>\n");
    try writer.writeAll(">\n");
    for (entries) |entry| {
        if (std.mem.startsWith(u8, entry.key, "@")) continue;
        try writeElement(writer, entry.key, entry.value, depth + 1, context);
    }
    try writer.splatByteAll(' ', depth * indent_width);
    try writer.print("</{s}>\n", .{name});
}

/// A text value, escaped so it is safe in element content and in double-quoted attributes.
fn writeText(writer: *std.Io.Writer, value: kosm.Value, name: []const u8, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    switch (value) {
        .string => |text| try writeEscaped(writer, text),
        .raw => |text| try writer.writeAll(text),
        .joined => |parts| for (parts) |part| try writeText(writer, part, name, context),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |float| {
            if (!std.math.isFinite(float)) return context.unsupported("'{s}' is infinite or NaN", .{name});
            try context.writeFloat(writer, float);
        },
        .boolean => |boolean| try context.writeBoolean(writer, boolean),
        .color => |color| {
            var buffer: [128]u8 = undefined;
            var color_writer: std.Io.Writer = .fixed(&buffer);
            context.writeColor(&color_writer, color) catch return context.unsupported("the color format prints more than {d} bytes", .{buffer.len});
            try writeEscaped(writer, color_writer.buffered());
        },
        .table, .list => return context.unsupported("'{s}' is a {s} where text belongs", .{ name, @tagName(value) }),
    }
}

fn writeEscaped(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |character| switch (character) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        else => try writer.writeByte(character),
    };
}

/// Element and attribute names: a letter, `_` or `:`, then letters, digits, `_`, `:`, `-` or `.`.
/// Bytes above ASCII pass, since XML allows most of Unicode in names.
fn checkName(name: []const u8, context: *kosm.Adapter.Context) error{UnsupportedValue}!void {
    const valid = name.len != 0 and !std.ascii.isDigit(name[0]) and name[0] != '-' and name[0] != '.' and for (name) |character| {
        if (!(std.ascii.isAlphanumeric(character) or character >= 0x80 or std.mem.indexOfScalar(u8, "_:-.", character) != null)) break false;
    } else true;
    if (!valid) return context.unsupported("'{s}' is not a valid XML name", .{name});
}

const testing = std.testing;

fn expectSerialized(expected: []const u8, root: kosm.Value) !void {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var context: kosm.Adapter.Context = .{ .format = adapter.default_format.resolve() };
    try serialize(&output.writer, root, &context);
    try testing.expectEqualStrings(expected, output.written());
}

fn expectUnsupported(message: []const u8, root: kosm.Value) !void {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var context: kosm.Adapter.Context = .{ .format = adapter.default_format.resolve() };
    try testing.expectError(error.UnsupportedValue, serialize(&output.writer, root, &context));
    try testing.expectEqualStrings(message, context.message());
}

test "lists repeat their element, attributes start with @, and text is escaped" {
    const families: []const kosm.Value = &.{ .{ .string = "Maple Mono" }, .{ .string = "Noto <Sans> & \"Co\"" } };
    try expectSerialized(
        \\<?xml version="1.0"?>
        \\<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
        \\<fontconfig>
        \\  <alias binding="strong">
        \\    <family>monospace</family>
        \\    <prefer>
        \\      <family>Maple Mono</family>
        \\      <family>Noto &lt;Sans&gt; &amp; &quot;Co&quot;</family>
        \\    </prefer>
        \\  </alias>
        \\  <empty size="12" on="true"/>
        \\  <color>#ff0000</color>
        \\</fontconfig>
        \\
    , .{ .table = &.{
        .{ .key = "!DOCTYPE", .value = .{ .raw = "fontconfig SYSTEM \"urn:fontconfig:fonts.dtd\"" } },
        .{ .key = "fontconfig", .value = .{ .table = &.{
            .{ .key = "alias", .value = .{ .list = &.{.{ .table = &.{
                .{ .key = "@binding", .value = .{ .string = "strong" } },
                .{ .key = "family", .value = .{ .string = "monospace" } },
                .{ .key = "prefer", .value = .{ .table = &.{.{ .key = "family", .value = .{ .list = families } }} } },
            } }} } },
            .{ .key = "empty", .value = .{ .table = &.{
                .{ .key = "@size", .value = .{ .integer = 12 } },
                .{ .key = "@on", .value = .{ .boolean = true } },
            } } },
            .{ .key = "color", .value = .{ .color = kosm.hex("#ff0000") } },
        } } },
    } });
}

test "serialize refuses values XML cannot hold" {
    try expectUnsupported("an XML file is a table holding its root element, not a string", .{ .string = "x" });
    try expectUnsupported("the file has no root element", .{ .table = &.{} });
    try expectUnsupported("an XML file has one root element, but 'a' and 'b' are both at the top", .{ .table = &.{
        .{ .key = "a", .value = .{ .integer = 1 } },
        .{ .key = "b", .value = .{ .integer = 2 } },
    } });
    try expectUnsupported("'1st' is not a valid XML name", .{ .table = &.{.{ .key = "1st", .value = .{ .integer = 1 } }} });
    try expectUnsupported("'a b' is not a valid XML name", .{ .table = &.{.{ .key = "a", .value = .{ .table = &.{.{ .key = "@a b", .value = .{ .integer = 1 } }} } }} });
    try expectUnsupported("'@size' is a table where text belongs", .{ .table = &.{.{ .key = "a", .value = .{ .table = &.{.{ .key = "@size", .value = .{ .table = &.{} } }} } }} });
    try expectUnsupported("element 'b' is a list of lists; wrap the inner lists in elements", .{ .table = &.{.{ .key = "a", .value = .{ .table = &.{.{ .key = "b", .value = .{ .list = &.{.{ .list = &.{} }} } }} } }} });
    try expectUnsupported("declaration '!DOCTYPE' comes after the root element; put it first", .{ .table = &.{
        .{ .key = "a", .value = .{ .integer = 1 } },
        .{ .key = "!DOCTYPE", .value = .{ .raw = "a" } },
    } });
}

test {
    std.testing.refAllDecls(@This());
}
