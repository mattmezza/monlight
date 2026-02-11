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

/// Extract the last File "...", line N location from a Python traceback.
///
/// Matches the Python traceback format:
///   File "/path/to/file.py", line 42, in function_name
///   File "/path/to/file.py", line 42
///
/// Returns the last match found (which is typically the deepest frame
/// in the call stack — where the exception was raised).
pub fn extractLastLocation(traceback: []const u8) ?TraceLocation {
    var last_location: ?TraceLocation = null;
    var pos: usize = 0;

    while (pos < traceback.len) {
        if (findFileLineAt(traceback, pos)) |result| {
            last_location = result.location;
            pos = result.end_pos;
        } else {
            // Advance to next line
            pos = nextLineStart(traceback, pos);
        }
    }

    return last_location;
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
