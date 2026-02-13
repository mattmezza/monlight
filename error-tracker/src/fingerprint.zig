const std = @import("std");
const Md5 = std.crypto.hash.Md5;

/// Result of parsing a traceback for the last code location.
pub const TraceLocation = struct {
    file: []const u8,
    line: []const u8,
};

/// Generate a 32-character hex fingerprint for an error.
///
/// Algorithm (per spec §4.5):
///   1. Extract exception type (provided as input)
///   2. Parse traceback to find the last application code location (file:line)
///   3. Concatenate: "{project}:{exception_type}:{file}:{line}"
///   4. Hash with MD5 to produce 32-char fingerprint
///
/// If no file/line can be extracted from the traceback, the full traceback
/// is used as the location component (still produces a deterministic fingerprint).
pub fn generate(project: []const u8, exception_type: []const u8, traceback: []const u8) [32]u8 {
    const location = extractLastLocation(traceback);

    var hasher = Md5.init(.{});
    hasher.update(project);
    hasher.update(":");
    hasher.update(exception_type);
    hasher.update(":");
    if (location) |loc| {
        hasher.update(loc.file);
        hasher.update(":");
        hasher.update(loc.line);
    } else {
        // Fallback: use the entire traceback as location component
        hasher.update(traceback);
    }

    var digest: [Md5.digest_length]u8 = undefined;
    hasher.final(&digest);

    return hexEncode(digest);
}

/// Encode a 16-byte MD5 digest as a 32-character lowercase hex string.
fn hexEncode(digest: [Md5.digest_length]u8) [32]u8 {
    const hex_chars = "0123456789abcdef";
    var result: [32]u8 = undefined;
    for (digest, 0..) |byte, i| {
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return result;
}

/// Extract the last File "...", line N location from a Python traceback,
/// or the first "at file:line:col" / "func@file:line:col" location from a
/// JavaScript stack trace.
///
/// Python format (returns LAST match — deepest frame):
///   File "/path/to/file.py", line 42, in function_name
///   File "/path/to/file.py", line 42
///
/// JavaScript Chrome/V8 format (returns FIRST match — throw site):
///   at functionName (http://example.com/app.js:10:5)
///   at http://example.com/app.js:10:5
///
/// JavaScript Firefox/Safari format (returns FIRST match — throw site):
///   functionName@http://example.com/app.js:10:5
///   @http://example.com/app.js:10:5
pub fn extractLastLocation(traceback: []const u8) ?TraceLocation {
    // Try Python format first (returns last match)
    if (extractPythonLocation(traceback)) |loc| return loc;
    // Try JavaScript format (returns first match — throw site is at top)
    if (extractJsLocation(traceback)) |loc| return loc;
    return null;
}

/// Extract the last File "...", line N location from a Python traceback.
fn extractPythonLocation(traceback: []const u8) ?TraceLocation {
    var last_location: ?TraceLocation = null;
    var pos: usize = 0;

    while (pos < traceback.len) {
        if (findFileLineAt(traceback, pos)) |result| {
            last_location = result.location;
            pos = result.end_pos;
        } else {
            pos = nextLineStart(traceback, pos);
        }
    }

    return last_location;
}

/// Extract the first JS stack location from a JavaScript stack trace.
/// Handles Chrome ("at func (file:line:col)") and Firefox/Safari ("func@file:line:col").
fn extractJsLocation(traceback: []const u8) ?TraceLocation {
    var pos: usize = 0;

    while (pos < traceback.len) {
        if (findJsFrameAt(traceback, pos)) |loc| return loc;
        pos = nextLineStart(traceback, pos);
    }

    return null;
}

/// Try to parse a JS stack frame from a line starting at `pos`.
fn findJsFrameAt(traceback: []const u8, start: usize) ?TraceLocation {
    // Find the end of this line
    var line_end = start;
    while (line_end < traceback.len and traceback[line_end] != '\n') {
        line_end += 1;
    }
    const line = traceback[start..line_end];

    // Skip empty lines
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return null;

    // Chrome/V8: "    at functionName (file:line:col)" or "    at file:line:col"
    if (std.mem.indexOf(u8, trimmed, "at ")) |at_pos| {
        const after_at = trimmed[at_pos + 3 ..];
        // Check for "(file:line:col)" format
        if (std.mem.indexOf(u8, after_at, "(")) |paren_start| {
            if (std.mem.indexOf(u8, after_at, ")")) |paren_end| {
                if (paren_end > paren_start) {
                    const inside = after_at[paren_start + 1 .. paren_end];
                    return parseFileLineCol(inside);
                }
            }
        }
        // No parens: "at file:line:col"
        return parseFileLineCol(after_at);
    }

    // Firefox/Safari: "functionName@file:line:col" or "@file:line:col"
    if (std.mem.indexOf(u8, trimmed, "@")) |at_sign| {
        const after_at = trimmed[at_sign + 1 ..];
        if (after_at.len > 0) {
            return parseFileLineCol(after_at);
        }
    }

    return null;
}

/// Parse a "file:line:col" or "file:line" string into a TraceLocation.
/// Handles URLs like "http://example.com/app.js:10:5" by finding line:col
/// from the end, working backwards past the column and line number.
fn parseFileLineCol(s: []const u8) ?TraceLocation {
    // Work backwards to find :col (optional) and :line
    // Pattern: anything:digits or anything:digits:digits
    const trimmed = std.mem.trim(u8, s, " \t\r");
    if (trimmed.len == 0) return null;

    // Find last colon — this separates col (or line if no col)
    const last_colon = std.mem.lastIndexOfScalar(u8, trimmed, ':') orelse return null;
    if (last_colon == 0) return null;

    // Check if what's after the last colon is all digits
    const after_last = trimmed[last_colon + 1 ..];
    if (after_last.len == 0 or !allDigits(after_last)) return null;

    // Check for a second-to-last colon (file:line:col case)
    const before_last = trimmed[0..last_colon];
    if (std.mem.lastIndexOfScalar(u8, before_last, ':')) |second_colon| {
        const between = before_last[second_colon + 1 ..];
        if (between.len > 0 and allDigits(between)) {
            // file:line:col — use line (between), file is before second colon
            const file = before_last[0..second_colon];
            if (file.len > 0) {
                return TraceLocation{
                    .file = file,
                    .line = between,
                };
            }
        }
    }

    // file:line — no column
    return TraceLocation{
        .file = before_last,
        .line = after_last,
    };
}

fn allDigits(s: []const u8) bool {
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return s.len > 0;
}

const FindResult = struct {
    location: TraceLocation,
    end_pos: usize,
};

/// Try to parse a `File "...", line N` pattern starting at or after `pos`.
fn findFileLineAt(traceback: []const u8, start: usize) ?FindResult {
    // Find 'File "' marker
    const marker = "File \"";
    const marker_pos = std.mem.indexOfPos(u8, traceback, start, marker) orelse return null;
    const file_start = marker_pos + marker.len;

    // Find closing quote for file path
    const quote_pos = std.mem.indexOfPos(u8, traceback, file_start, "\"") orelse return null;
    const file_path = traceback[file_start..quote_pos];

    // Find ", line " after the closing quote
    const line_marker = ", line ";
    const after_quote = quote_pos + 1;
    if (after_quote + line_marker.len > traceback.len) return null;

    if (!std.mem.eql(u8, traceback[after_quote .. after_quote + line_marker.len], line_marker)) return null;

    const line_num_start = after_quote + line_marker.len;

    // Extract line number (sequence of digits)
    var line_num_end = line_num_start;
    while (line_num_end < traceback.len and traceback[line_num_end] >= '0' and traceback[line_num_end] <= '9') {
        line_num_end += 1;
    }

    if (line_num_end == line_num_start) return null; // No digits found

    const line_number = traceback[line_num_start..line_num_end];

    return FindResult{
        .location = TraceLocation{
            .file = file_path,
            .line = line_number,
        },
        .end_pos = line_num_end,
    };
}

/// Advance past the current line to the start of the next line.
fn nextLineStart(text: []const u8, pos: usize) usize {
    var p = pos;
    while (p < text.len and text[p] != '\n') {
        p += 1;
    }
    if (p < text.len) p += 1; // skip the newline
    return p;
}

// =============================================================================
// Tests
// =============================================================================

test "generate produces 32-character hex string" {
    const fp = generate("flowrent", "ValueError", "some traceback");
    try std.testing.expectEqual(@as(usize, 32), fp.len);

    // Verify all characters are lowercase hex
    for (fp) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(is_hex);
    }
}

test "generate is deterministic — same inputs produce same fingerprint" {
    const traceback =
        \\Traceback (most recent call last):
        \\  File "/app/app/routes/bookings.py", line 142, in create_booking
        \\    validate_input(data)
        \\  File "/app/app/utils/validation.py", line 56, in validate_input
        \\    raise ValueError("invalid input")
        \\ValueError: invalid input
    ;

    const fp1 = generate("flowrent", "ValueError", traceback);
    const fp2 = generate("flowrent", "ValueError", traceback);

    try std.testing.expectEqualSlices(u8, &fp1, &fp2);
}

test "generate produces different fingerprints for different stack locations" {
    const tb1 =
        \\Traceback (most recent call last):
        \\  File "/app/app/utils/validation.py", line 56, in validate_input
        \\    raise ValueError("invalid input")
        \\ValueError: invalid input
    ;

    const tb2 =
        \\Traceback (most recent call last):
        \\  File "/app/app/utils/validation.py", line 99, in validate_input
        \\    raise ValueError("invalid input")
        \\ValueError: invalid input
    ;

    const fp1 = generate("flowrent", "ValueError", tb1);
    const fp2 = generate("flowrent", "ValueError", tb2);

    try std.testing.expect(!std.mem.eql(u8, &fp1, &fp2));
}

test "generate produces different fingerprints for different files" {
    const tb1 =
        \\Traceback (most recent call last):
        \\  File "/app/app/routes/bookings.py", line 42, in create
        \\    do_something()
        \\ValueError: bad
    ;

    const tb2 =
        \\Traceback (most recent call last):
        \\  File "/app/app/routes/users.py", line 42, in create
        \\    do_something()
        \\ValueError: bad
    ;

    const fp1 = generate("flowrent", "ValueError", tb1);
    const fp2 = generate("flowrent", "ValueError", tb2);

    try std.testing.expect(!std.mem.eql(u8, &fp1, &fp2));
}

test "generate produces different fingerprints for different exception types" {
    const traceback =
        \\Traceback (most recent call last):
        \\  File "/app/app/utils/validation.py", line 56, in validate_input
        \\    raise ValueError("invalid input")
        \\ValueError: invalid input
    ;

    const fp1 = generate("flowrent", "ValueError", traceback);
    const fp2 = generate("flowrent", "TypeError", traceback);

    try std.testing.expect(!std.mem.eql(u8, &fp1, &fp2));
}

test "generate produces different fingerprints for different projects" {
    const traceback =
        \\Traceback (most recent call last):
        \\  File "/app/app/utils/validation.py", line 56, in validate_input
        \\    raise ValueError("invalid input")
        \\ValueError: invalid input
    ;

    const fp1 = generate("flowrent", "ValueError", traceback);
    const fp2 = generate("other-app", "ValueError", traceback);

    try std.testing.expect(!std.mem.eql(u8, &fp1, &fp2));
}

test "extractLastLocation finds last File/line in multi-frame traceback" {
    const traceback =
        \\Traceback (most recent call last):
        \\  File "/app/app/routes/bookings.py", line 142, in create_booking
        \\    validate_input(data)
        \\  File "/app/app/utils/validation.py", line 56, in validate_input
        \\    raise ValueError("invalid input")
        \\ValueError: invalid input
    ;

    const loc = extractLastLocation(traceback).?;
    try std.testing.expectEqualSlices(u8, "/app/app/utils/validation.py", loc.file);
    try std.testing.expectEqualSlices(u8, "56", loc.line);
}

test "extractLastLocation finds single-frame traceback" {
    const traceback =
        \\Traceback (most recent call last):
        \\  File "/app/main.py", line 10, in main
        \\    run()
        \\RuntimeError: boom
    ;

    const loc = extractLastLocation(traceback).?;
    try std.testing.expectEqualSlices(u8, "/app/main.py", loc.file);
    try std.testing.expectEqualSlices(u8, "10", loc.line);
}

test "extractLastLocation returns null for non-traceback text" {
    const text = "This is not a traceback at all";
    try std.testing.expectEqual(@as(?TraceLocation, null), extractLastLocation(text));
}

test "extractLastLocation handles traceback without 'in function' part" {
    const traceback =
        \\Traceback (most recent call last):
        \\  File "/app/main.py", line 5
        \\    run()
        \\RuntimeError: boom
    ;

    const loc = extractLastLocation(traceback).?;
    try std.testing.expectEqualSlices(u8, "/app/main.py", loc.file);
    try std.testing.expectEqualSlices(u8, "5", loc.line);
}

test "generate with no traceback location falls back gracefully" {
    // Even without a parseable traceback, we should still get a valid 32-char hex fingerprint
    const fp = generate("myproject", "SomeError", "no traceback here");
    try std.testing.expectEqual(@as(usize, 32), fp.len);

    // And it should be deterministic
    const fp2 = generate("myproject", "SomeError", "no traceback here");
    try std.testing.expectEqualSlices(u8, &fp, &fp2);
}

test "generate with spec example" {
    // Verify against the spec example:
    // Key: "flowrent:ValueError:/app/app/utils/validation.py:56"
    const traceback =
        \\Traceback (most recent call last):
        \\  File "/app/app/routes/bookings.py", line 142, in create_booking
        \\    validate_input(data)
        \\  File "/app/app/utils/validation.py", line 56, in validate_input
        \\    raise ValueError("invalid input")
        \\ValueError: invalid input
    ;

    const fp = generate("flowrent", "ValueError", traceback);

    // The key should be "flowrent:ValueError:/app/app/utils/validation.py:56"
    // Compute expected MD5 manually
    var expected_digest: [Md5.digest_length]u8 = undefined;
    Md5.hash("flowrent:ValueError:/app/app/utils/validation.py:56", &expected_digest, .{});
    const expected = hexEncode(expected_digest);

    try std.testing.expectEqualSlices(u8, &expected, &fp);
}

test "hexEncode produces correct output" {
    const input = [_]u8{ 0x00, 0x01, 0x0a, 0xff, 0xca, 0xfe, 0xba, 0xbe, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0 };
    const result = hexEncode(input);
    try std.testing.expectEqualSlices(u8, "00010affcafebabe123456789abcdef0", &result);
}

// =============================================================================
// JavaScript stack trace fingerprinting tests
// =============================================================================

test "extractLastLocation handles Chrome V8 stack trace with function name" {
    const traceback =
        \\TypeError: Cannot read property 'x' of undefined
        \\    at Object.handleClick (http://example.com/static/app.js:42:15)
        \\    at HTMLButtonElement.<anonymous> (http://example.com/static/app.js:100:3)
    ;

    const loc = extractLastLocation(traceback).?;
    // Should return the FIRST frame (throw site) for JS traces
    try std.testing.expectEqualSlices(u8, "http://example.com/static/app.js", loc.file);
    try std.testing.expectEqualSlices(u8, "42", loc.line);
}

test "extractLastLocation handles Chrome V8 stack trace without function name" {
    const traceback =
        \\Error: Network error
        \\    at http://example.com/bundle.js:10:5
        \\    at http://example.com/bundle.js:200:12
    ;

    const loc = extractLastLocation(traceback).?;
    try std.testing.expectEqualSlices(u8, "http://example.com/bundle.js", loc.file);
    try std.testing.expectEqualSlices(u8, "10", loc.line);
}

test "extractLastLocation handles Firefox/Safari stack trace" {
    const traceback =
        \\handleClick@http://example.com/static/app.js:42:15
        \\@http://example.com/static/app.js:100:3
    ;

    const loc = extractLastLocation(traceback).?;
    try std.testing.expectEqualSlices(u8, "http://example.com/static/app.js", loc.file);
    try std.testing.expectEqualSlices(u8, "42", loc.line);
}

test "extractLastLocation handles deobfuscated JS stack trace" {
    // After source map deobfuscation, the stack might reference original source files
    const traceback =
        \\TypeError: Cannot read property 'name' of undefined
        \\    at UserProfile.render (src/components/UserProfile.tsx:28:12)
        \\    at App.render (src/App.tsx:15:8)
    ;

    const loc = extractLastLocation(traceback).?;
    try std.testing.expectEqualSlices(u8, "src/components/UserProfile.tsx", loc.file);
    try std.testing.expectEqualSlices(u8, "28", loc.line);
}

test "generate produces consistent fingerprints for JS stack traces" {
    const traceback1 =
        \\TypeError: Cannot read property 'x' of undefined
        \\    at Object.handleClick (http://example.com/app.js:42:15)
        \\    at HTMLButtonElement.<anonymous> (http://example.com/app.js:100:3)
    ;
    const traceback2 =
        \\TypeError: Cannot read property 'x' of undefined
        \\    at Object.handleClick (http://example.com/app.js:42:15)
        \\    at HTMLButtonElement.<anonymous> (http://example.com/app.js:100:3)
    ;

    const fp1 = generate("myapp", "TypeError", traceback1);
    const fp2 = generate("myapp", "TypeError", traceback2);
    try std.testing.expectEqualSlices(u8, &fp1, &fp2);
}

test "generate produces different fingerprints for JS errors at different locations" {
    const traceback1 =
        \\TypeError: Cannot read property 'x' of undefined
        \\    at Object.handleClick (http://example.com/app.js:42:15)
    ;
    const traceback2 =
        \\TypeError: Cannot read property 'x' of undefined
        \\    at Object.handleClick (http://example.com/app.js:99:15)
    ;

    const fp1 = generate("myapp", "TypeError", traceback1);
    const fp2 = generate("myapp", "TypeError", traceback2);
    try std.testing.expect(!std.mem.eql(u8, &fp1, &fp2));
}

test "generate same location different column produces same fingerprint" {
    // Same file:line but different column should group together
    const traceback1 =
        \\TypeError: Cannot read property 'x' of undefined
        \\    at Object.handleClick (http://example.com/app.js:42:15)
    ;
    const traceback2 =
        \\TypeError: Cannot read property 'x' of undefined
        \\    at Object.handleClick (http://example.com/app.js:42:99)
    ;

    const fp1 = generate("myapp", "TypeError", traceback1);
    const fp2 = generate("myapp", "TypeError", traceback2);
    // Column differs but file:line is the same — should produce same fingerprint
    try std.testing.expectEqualSlices(u8, &fp1, &fp2);
}

test "generate JS fingerprint uses file and line for hash key" {
    const traceback =
        \\TypeError: x is not defined
        \\    at doWork (http://example.com/app.js:42:15)
    ;

    const fp = generate("myapp", "TypeError", traceback);

    // Expected key: "myapp:TypeError:http://example.com/app.js:42"
    var expected_digest: [Md5.digest_length]u8 = undefined;
    Md5.hash("myapp:TypeError:http://example.com/app.js:42", &expected_digest, .{});
    const expected = hexEncode(expected_digest);

    try std.testing.expectEqualSlices(u8, &expected, &fp);
}

test "extractLastLocation handles Firefox anonymous at-sign format" {
    const traceback =
        \\@http://example.com/app.js:10:5
    ;

    const loc = extractLastLocation(traceback).?;
    try std.testing.expectEqualSlices(u8, "http://example.com/app.js", loc.file);
    try std.testing.expectEqualSlices(u8, "10", loc.line);
}

test "extractLastLocation prefers Python over JS when Python format is present" {
    // If both formats are somehow present, Python should win
    const traceback =
        \\Traceback (most recent call last):
        \\  File "/app/main.py", line 10, in main
        \\    at something (http://example.com/app.js:42:15)
    ;

    const loc = extractLastLocation(traceback).?;
    try std.testing.expectEqualSlices(u8, "/app/main.py", loc.file);
    try std.testing.expectEqualSlices(u8, "10", loc.line);
}
