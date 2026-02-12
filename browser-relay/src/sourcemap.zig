const std = @import("std");
const log = std.log;

// ============================================================
// Base64 VLQ Decoder
// ============================================================

/// Base64 character → 6-bit value lookup table.
/// Invalid characters map to 255.
const base64_table: [256]u8 = blk: {
    var table = [_]u8{255} ** 256;
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (chars, 0..) |c, i| {
        table[c] = @intCast(i);
    }
    break :blk table;
};

/// Decode a single Base64 VLQ value from the mappings string.
/// Returns the decoded signed integer and the number of characters consumed.
/// Returns null if the input is invalid.
fn decodeVlq(data: []const u8) ?struct { value: i64, consumed: usize } {
    var result: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;

    while (i < data.len) {
        const b64_val = base64_table[data[i]];
        if (b64_val == 255) return null; // invalid base64 char

        const digit: u64 = @intCast(b64_val);
        // Lower 4 bits of first digit, all 5 bits of subsequent
        if (shift == 0) {
            // First byte: bit 0 = sign, bits 1-4 = value, bit 5 = continuation
            result = (digit >> 1) & 0xF;
        } else {
            // VLQ uses 5 bits of data per continuation byte
            const data_bits: u64 = digit & 0x1F;
            // shift was incremented by 4 after first byte, then by 5 for each subsequent
            result |= data_bits << shift;
        }

        i += 1;

        // Bit 5 (0x20) is the continuation bit
        if ((digit & 0x20) == 0) {
            // No more continuation bytes
            // For first byte, bit 0 is sign
            const first_b64 = base64_table[data[0]];
            const first_digit: u64 = @intCast(first_b64);
            const is_negative = (first_digit & 1) == 1;

            const signed: i64 = @intCast(result);
            return .{
                .value = if (is_negative) -signed else signed,
                .consumed = i,
            };
        }

        if (shift == 0) {
            shift = 4;
        } else {
            shift += 5;
        }
    }

    return null; // ran out of input with continuation bit set
}

// ============================================================
// Source Map Segment / Mapping Entry
// ============================================================

/// A single decoded mapping entry.
pub const MappingEntry = struct {
    generated_line: u32, // 0-based
    generated_col: u32, // 0-based
    source_index: ?u32, // index into "sources" array
    original_line: ?u32, // 0-based
    original_col: ?u32, // 0-based
    name_index: ?u32, // index into "names" array
};

/// Parsed source map with decoded mappings ready for lookup.
pub const SourceMap = struct {
    sources: []const []const u8,
    names: []const []const u8,
    entries: []const MappingEntry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SourceMap) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.sources);
        self.allocator.free(self.names);
    }

    /// Look up the original position for a generated line:col (both 1-based input).
    /// Returns the original source file, line (1-based), column (1-based), and optional name.
    pub fn lookup(self: *const SourceMap, gen_line_1: u32, gen_col_1: u32) ?LookupResult {
        if (gen_line_1 == 0 or gen_col_1 == 0) return null;
        const gen_line: u32 = gen_line_1 - 1; // convert to 0-based
        const gen_col: u32 = gen_col_1 - 1;

        // Binary search: find the last entry where generated_line <= gen_line
        // and within that line, generated_col <= gen_col.
        // Entries are sorted by (generated_line, generated_col).
        var best: ?usize = null;

        // Find the range of entries on this line using binary search
        var lo: usize = 0;
        var hi: usize = self.entries.len;

        // Find first entry with generated_line >= gen_line
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.entries[mid].generated_line < gen_line) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        // Now scan entries on this line to find the best match (largest col <= gen_col)
        var i = lo;
        while (i < self.entries.len and self.entries[i].generated_line == gen_line) {
            if (self.entries[i].generated_col <= gen_col) {
                best = i;
            } else {
                break; // entries are sorted by col within a line
            }
            i += 1;
        }

        if (best) |idx| {
            const entry = self.entries[idx];
            if (entry.source_index == null or entry.original_line == null or entry.original_col == null) {
                return null;
            }

            const src_idx = entry.source_index.?;
            if (src_idx >= self.sources.len) return null;

            return LookupResult{
                .source = self.sources[src_idx],
                .line = entry.original_line.? + 1, // convert to 1-based
                .column = entry.original_col.? + 1,
                .name = if (entry.name_index) |ni| (if (ni < self.names.len) self.names[ni] else null) else null,
            };
        }

        return null;
    }
};

pub const LookupResult = struct {
    source: []const u8,
    line: u32,
    column: u32,
    name: ?[]const u8,
};

/// Parse a source map JSON string into a SourceMap.
/// Caller must call deinit() on the returned SourceMap.
pub fn parseSourceMap(allocator: std.mem.Allocator, json_content: []const u8) !SourceMap {
    // Parse JSON
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, json_content, .{}) catch {
        return error.InvalidJson;
    };

    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.InvalidSourceMap,
    };

    // Extract sources array
    const sources_val = obj.get("sources") orelse return error.MissingSources;
    const sources_arr = switch (sources_val) {
        .array => |a| a,
        else => return error.InvalidSources,
    };

    var sources = try allocator.alloc([]const u8, sources_arr.items.len);
    for (sources_arr.items, 0..) |item, i| {
        sources[i] = switch (item) {
            .string => |s| s,
            else => "",
        };
    }

    // Extract names array (optional)
    const names: []const []const u8 = blk: {
        if (obj.get("names")) |names_val| {
            const names_arr = switch (names_val) {
                .array => |a| a,
                else => null,
            };
            if (names_arr) |arr| {
                const n = try allocator.alloc([]const u8, arr.items.len);
                for (arr.items, 0..) |item, i| {
                    n[i] = switch (item) {
                        .string => |s| s,
                        else => "",
                    };
                }
                break :blk n;
            }
        }
        break :blk &.{};
    };

    // Extract and decode mappings
    const mappings_val = obj.get("mappings") orelse return error.MissingMappings;
    const mappings_str = switch (mappings_val) {
        .string => |s| s,
        else => return error.InvalidMappings,
    };

    const entries = try decodeMappings(allocator, mappings_str);

    return SourceMap{
        .sources = sources,
        .names = names,
        .entries = entries,
        .allocator = allocator,
    };
}

/// Decode the VLQ-encoded mappings string into an array of MappingEntry.
fn decodeMappings(allocator: std.mem.Allocator, mappings: []const u8) ![]MappingEntry {
    // Pre-count approximate number of entries to minimize allocations
    var entry_count: usize = 0;
    for (mappings) |c| {
        if (c != ',' and c != ';') {
            // Only count when we transition from separator to non-separator
        } else {
            if (c == ';') entry_count += 0; // line separators don't add entries
        }
    }
    // Rough estimate: each segment has at least 1 char
    var entries = std.ArrayList(MappingEntry).init(allocator);
    defer entries.deinit();

    var generated_line: u32 = 0;
    var generated_col: i64 = 0;
    var source_index: i64 = 0;
    var original_line: i64 = 0;
    var original_col: i64 = 0;
    var name_index: i64 = 0;

    var pos: usize = 0;

    while (pos < mappings.len) {
        const c = mappings[pos];

        if (c == ';') {
            // New generated line
            generated_line += 1;
            generated_col = 0; // reset column for new line
            pos += 1;
            continue;
        }

        if (c == ',') {
            pos += 1;
            continue;
        }

        // Decode a segment (1, 4, or 5 VLQ values)
        // Field 1: generated column (relative to previous in same line)
        const col_vlq = decodeVlq(mappings[pos..]) orelse return error.InvalidVlq;
        generated_col += col_vlq.value;
        pos += col_vlq.consumed;

        // Check if there are more fields in this segment
        if (pos >= mappings.len or mappings[pos] == ',' or mappings[pos] == ';') {
            // 1-field segment: only generated column
            try entries.append(.{
                .generated_line = generated_line,
                .generated_col = @intCast(@as(u64, @bitCast(generated_col))),
                .source_index = null,
                .original_line = null,
                .original_col = null,
                .name_index = null,
            });
            continue;
        }

        // Field 2: source file index (relative)
        const src_vlq = decodeVlq(mappings[pos..]) orelse return error.InvalidVlq;
        source_index += src_vlq.value;
        pos += src_vlq.consumed;

        // Field 3: original line (relative)
        const line_vlq = decodeVlq(mappings[pos..]) orelse return error.InvalidVlq;
        original_line += line_vlq.value;
        pos += line_vlq.consumed;

        // Field 4: original column (relative)
        const ocol_vlq = decodeVlq(mappings[pos..]) orelse return error.InvalidVlq;
        original_col += ocol_vlq.value;
        pos += ocol_vlq.consumed;

        // Check for optional field 5: name index
        var entry_name_index: ?u32 = null;
        if (pos < mappings.len and mappings[pos] != ',' and mappings[pos] != ';') {
            const name_vlq = decodeVlq(mappings[pos..]) orelse return error.InvalidVlq;
            name_index += name_vlq.value;
            pos += name_vlq.consumed;
            entry_name_index = @intCast(@as(u64, @bitCast(name_index)));
        }

        try entries.append(.{
            .generated_line = generated_line,
            .generated_col = @intCast(@as(u64, @bitCast(generated_col))),
            .source_index = @intCast(@as(u64, @bitCast(source_index))),
            .original_line = @intCast(@as(u64, @bitCast(original_line))),
            .original_col = @intCast(@as(u64, @bitCast(original_col))),
            .name_index = entry_name_index,
        });
    }

    return try entries.toOwnedSlice();
}

// ============================================================
// JavaScript Stack Trace Parser
// ============================================================

/// A parsed stack frame from a JavaScript error.
pub const StackFrame = struct {
    function_name: ?[]const u8,
    file_url: []const u8,
    line: u32,
    column: u32,
    raw_line: []const u8, // the original line of text
};

/// Parse a JavaScript stack trace string into individual frames.
/// Supports Chrome/V8, Firefox, and Safari formats.
pub fn parseStackTrace(allocator: std.mem.Allocator, stack: []const u8) ![]StackFrame {
    var frames = std.ArrayList(StackFrame).init(allocator);
    defer frames.deinit();

    var line_iter = std.mem.splitScalar(u8, stack, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Try Chrome/V8 format: "    at functionName (file:line:col)"
        //                    or: "    at file:line:col"
        if (parseChromeFrame(trimmed)) |frame| {
            var f = frame;
            f.raw_line = trimmed;
            try frames.append(f);
            continue;
        }

        // Try Firefox/Safari format: "functionName@file:line:col"
        //                         or: "@file:line:col"
        if (parseFirefoxFrame(trimmed)) |frame| {
            var f = frame;
            f.raw_line = trimmed;
            try frames.append(f);
            continue;
        }

        // Skip lines we can't parse (e.g. error message line)
    }

    return try frames.toOwnedSlice();
}

/// Parse a Chrome/V8 style stack frame:
///   "at functionName (file:line:col)"
///   "at file:line:col"
///   "at functionName (http://example.com/file.js:10:5)"
///   "at new ClassName (file:line:col)"
fn parseChromeFrame(line: []const u8) ?StackFrame {
    // Must start with "at "
    if (!std.mem.startsWith(u8, line, "at ")) return null;
    const rest = line[3..];

    // Check if there's a parenthesized location
    if (std.mem.lastIndexOfScalar(u8, rest, ')')) |close_paren| {
        // Find the matching open paren
        if (std.mem.lastIndexOfScalar(u8, rest[0..close_paren], '(')) |open_paren| {
            const func_name = std.mem.trim(u8, rest[0..open_paren], " ");
            const location = rest[open_paren + 1 .. close_paren];
            if (parseLocation(location)) |loc| {
                return StackFrame{
                    .function_name = if (func_name.len > 0) func_name else null,
                    .file_url = loc.file,
                    .line = loc.line,
                    .column = loc.col,
                    .raw_line = line,
                };
            }
        }
    }

    // No parens — the whole rest is the location
    if (parseLocation(rest)) |loc| {
        return StackFrame{
            .function_name = null,
            .file_url = loc.file,
            .line = loc.line,
            .column = loc.col,
            .raw_line = line,
        };
    }

    return null;
}

/// Parse a Firefox/Safari style stack frame:
///   "functionName@file:line:col"
///   "@file:line:col"
fn parseFirefoxFrame(line: []const u8) ?StackFrame {
    // Must contain '@'
    const at_idx = std.mem.indexOfScalar(u8, line, '@') orelse return null;

    const func_name = line[0..at_idx];
    const location = line[at_idx + 1 ..];

    if (parseLocation(location)) |loc| {
        return StackFrame{
            .function_name = if (func_name.len > 0) func_name else null,
            .file_url = loc.file,
            .line = loc.line,
            .column = loc.col,
            .raw_line = line,
        };
    }

    return null;
}

const LocationParts = struct {
    file: []const u8,
    line: u32,
    col: u32,
};

/// Parse "file:line:col" from the end of a location string.
/// Handles URLs with colons (http://...) by parsing line:col from the end.
fn parseLocation(location: []const u8) ?LocationParts {
    if (location.len == 0) return null;

    // Parse col from the end: find last ':'
    const last_colon = std.mem.lastIndexOfScalar(u8, location, ':') orelse return null;
    if (last_colon == 0) return null;

    const col_str = location[last_colon + 1 ..];
    const col = std.fmt.parseInt(u32, col_str, 10) catch return null;

    // Parse line: find second-to-last ':'
    const before_col = location[0..last_colon];
    const line_colon = std.mem.lastIndexOfScalar(u8, before_col, ':') orelse return null;

    const line_str = before_col[line_colon + 1 ..];
    const line_num = std.fmt.parseInt(u32, line_str, 10) catch return null;

    const file = location[0..line_colon];
    if (file.len == 0) return null;

    return LocationParts{
        .file = file,
        .line = line_num,
        .col = col,
    };
}

// ============================================================
// Stack Trace Rewriter
// ============================================================

/// Rewrite a JavaScript stack trace using source maps.
/// For each frame, looks up the source map and replaces minified
/// file:line:col with original file:line:col.
///
/// `lookupSourceMap` is called with (project, release, file_url) and
/// should return the source map JSON content, or null if not found.
///
/// Returns the rewritten stack trace as a new string allocated with `allocator`.
pub fn rewriteStackTrace(
    allocator: std.mem.Allocator,
    stack: []const u8,
    project: []const u8,
    release: []const u8,
    lookupFn: *const fn ([]const u8, []const u8, []const u8) ?[]const u8,
) ![]const u8 {
    const frames = try parseStackTrace(allocator, stack);
    defer allocator.free(frames);

    if (frames.len == 0) return try allocator.dupe(u8, stack);

    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    var line_iter = std.mem.splitScalar(u8, stack, '\n');
    var frame_idx: usize = 0;

    while (line_iter.next()) |line| {
        if (result.items.len > 0) {
            try result.append('\n');
        }

        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Check if this line matches the current frame
        if (frame_idx < frames.len and std.mem.eql(u8, trimmed, frames[frame_idx].raw_line)) {
            const frame = frames[frame_idx];
            frame_idx += 1;

            // Extract just the filename/path from the URL for source map lookup
            const file_url = normalizeFileUrl(frame.file_url);

            // Look up source map for this file
            if (lookupFn(project, release, file_url)) |map_content| {
                // Parse source map and look up original position
                var source_map = parseSourceMap(allocator, map_content) catch {
                    // Can't parse source map, keep original line
                    try result.appendSlice(line);
                    continue;
                };
                defer source_map.deinit();

                if (source_map.lookup(frame.line, frame.column)) |original| {
                    // Rewrite the frame with original location
                    try writeRewrittenFrame(&result, frame, original, line);
                    continue;
                }
            }

            // No source map or no mapping found — keep original line
            try result.appendSlice(line);
        } else {
            // Not a frame line, keep as-is
            try result.appendSlice(line);
        }
    }

    return try result.toOwnedSlice();
}

/// Normalize a file URL for source map lookup.
/// Strips protocol and domain, returning just the path.
/// E.g. "http://example.com/static/app.min.js" → "/static/app.min.js"
fn normalizeFileUrl(url: []const u8) []const u8 {
    // Check for protocol://
    if (std.mem.indexOf(u8, url, "://")) |proto_end| {
        const after_proto = url[proto_end + 3 ..];
        // Find the first '/' after the domain
        if (std.mem.indexOfScalar(u8, after_proto, '/')) |path_start| {
            return after_proto[path_start..];
        }
        return "/"; // URL with domain but no path
    }
    return url; // Already a path
}

/// Write a rewritten stack frame to the output.
fn writeRewrittenFrame(
    result: *std.ArrayList(u8),
    frame: StackFrame,
    original: LookupResult,
    original_line: []const u8,
) !void {
    // Detect indentation from original line
    var indent: usize = 0;
    while (indent < original_line.len and (original_line[indent] == ' ' or original_line[indent] == '\t')) {
        indent += 1;
    }
    const indent_str = original_line[0..indent];

    // Determine format based on original frame format
    if (std.mem.indexOf(u8, frame.raw_line, "at ") != null) {
        // Chrome format
        try result.appendSlice(indent_str);
        try result.appendSlice("at ");
        if (original.name) |name| {
            try result.appendSlice(name);
            try result.appendSlice(" (");
            try result.appendSlice(original.source);
            try result.appendSlice(":");
            try appendU32(result, original.line);
            try result.appendSlice(":");
            try appendU32(result, original.column);
            try result.appendSlice(")");
        } else if (frame.function_name) |func| {
            try result.appendSlice(func);
            try result.appendSlice(" (");
            try result.appendSlice(original.source);
            try result.appendSlice(":");
            try appendU32(result, original.line);
            try result.appendSlice(":");
            try appendU32(result, original.column);
            try result.appendSlice(")");
        } else {
            try result.appendSlice(original.source);
            try result.appendSlice(":");
            try appendU32(result, original.line);
            try result.appendSlice(":");
            try appendU32(result, original.column);
        }
    } else {
        // Firefox/Safari format
        try result.appendSlice(indent_str);
        if (original.name) |name| {
            try result.appendSlice(name);
        } else if (frame.function_name) |func| {
            try result.appendSlice(func);
        }
        try result.appendSlice("@");
        try result.appendSlice(original.source);
        try result.appendSlice(":");
        try appendU32(result, original.line);
        try result.appendSlice(":");
        try appendU32(result, original.column);
    }
}

fn appendU32(list: *std.ArrayList(u8), value: u32) !void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    try list.appendSlice(s);
}

// ============================================================
// Database lookup helper
// ============================================================

const sqlite = @import("sqlite");

/// Look up source map content from the database for the given project, release, and file_url.
pub fn lookupSourceMapFromDb(db: *sqlite.Database, project: []const u8, release: []const u8, file_url: []const u8) ?[]const u8 {
    const stmt = db.prepare(
        "SELECT map_content FROM source_maps WHERE project = ? AND release = ? AND file_url = ?;",
    ) catch return null;
    defer stmt.deinit();

    stmt.bindText(1, project) catch return null;
    stmt.bindText(2, release) catch return null;
    stmt.bindText(3, file_url) catch return null;

    var iter = stmt.query();
    if (iter.next()) |row| {
        return row.text(0);
    }
    return null;
}

/// Deobfuscate a stack trace using source maps from the database.
/// This is the main entry point for the browser_errors module.
/// Returns the deobfuscated stack trace, or the original if no source maps are found.
pub fn deobfuscateStackTrace(
    allocator: std.mem.Allocator,
    stack: []const u8,
    project: []const u8,
    release: []const u8,
    db: *sqlite.Database,
) ![]const u8 {
    const frames = try parseStackTrace(allocator, stack);
    defer allocator.free(frames);

    if (frames.len == 0) return try allocator.dupe(u8, stack);

    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    // Cache parsed source maps by file_url to avoid re-parsing
    var sm_cache = std.StringHashMap(?SourceMapCacheEntry).init(allocator);
    defer {
        var it = sm_cache.valueIterator();
        while (it.next()) |v| {
            if (v.*) |*entry| {
                entry.sm.deinit();
            }
        }
        sm_cache.deinit();
    }

    var line_iter = std.mem.splitScalar(u8, stack, '\n');
    var frame_idx: usize = 0;

    while (line_iter.next()) |line| {
        if (result.items.len > 0) {
            try result.append('\n');
        }

        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (frame_idx < frames.len and std.mem.eql(u8, trimmed, frames[frame_idx].raw_line)) {
            const frame = frames[frame_idx];
            frame_idx += 1;

            const file_url = normalizeFileUrl(frame.file_url);

            // Check cache first
            const cached = sm_cache.get(file_url);
            if (cached) |cache_entry| {
                if (cache_entry) |*entry| {
                    if (entry.sm.lookup(frame.line, frame.column)) |original| {
                        try writeRewrittenFrame(&result, frame, original, line);
                        continue;
                    }
                }
                // Cached as null (no source map found) or no mapping
                try result.appendSlice(line);
                continue;
            }

            // Not cached — look up from DB
            if (lookupSourceMapFromDb(db, project, release, file_url)) |map_content| {
                // Need to dupe the content since the DB row may be freed
                const duped = allocator.dupe(u8, map_content) catch {
                    try result.appendSlice(line);
                    continue;
                };

                var sm = parseSourceMap(allocator, duped) catch {
                    sm_cache.put(file_url, null) catch {};
                    try result.appendSlice(line);
                    continue;
                };

                if (sm.lookup(frame.line, frame.column)) |original| {
                    try writeRewrittenFrame(&result, frame, original, line);
                    sm_cache.put(file_url, SourceMapCacheEntry{ .sm = sm }) catch {
                        sm.deinit();
                    };
                    continue;
                }

                sm_cache.put(file_url, SourceMapCacheEntry{ .sm = sm }) catch {
                    sm.deinit();
                };
            } else {
                sm_cache.put(file_url, null) catch {};
            }

            try result.appendSlice(line);
        } else {
            try result.appendSlice(line);
        }
    }

    return try result.toOwnedSlice();
}

const SourceMapCacheEntry = struct {
    sm: SourceMap,
};

// ============================================================
// Unit Tests
// ============================================================

test "decodeVlq basic values" {
    // 'A' = 0 → value 0
    {
        const result = decodeVlq("A").?;
        try std.testing.expectEqual(@as(i64, 0), result.value);
        try std.testing.expectEqual(@as(usize, 1), result.consumed);
    }
    // 'C' = 2 → bit0=0 (positive), bits1-4=1 → value 1
    {
        const result = decodeVlq("C").?;
        try std.testing.expectEqual(@as(i64, 1), result.value);
        try std.testing.expectEqual(@as(usize, 1), result.consumed);
    }
    // 'D' = 3 → bit0=1 (negative), bits1-4=1 → value -1
    {
        const result = decodeVlq("D").?;
        try std.testing.expectEqual(@as(i64, -1), result.value);
        try std.testing.expectEqual(@as(usize, 1), result.consumed);
    }
    // 'E' = 4 → bit0=0, bits1-4=2 → value 2
    {
        const result = decodeVlq("E").?;
        try std.testing.expectEqual(@as(i64, 2), result.value);
        try std.testing.expectEqual(@as(usize, 1), result.consumed);
    }
}

test "decodeVlq multi-byte" {
    // 'gB' → continuation byte 'g' (32+6=38 → digit 32, bit5=1 cont, data=6>>1=3, sign=0)
    // Actually let me test with known values.
    // Value 16: needs continuation. 16 in VLQ:
    //   16 << 1 = 32 (since positive, sign bit 0)
    //   First 5 bits: 32 & 0x1F = 0, set continuation: 0 | 0x20 = 32 → 'g'
    //   Remaining: 32 >> 5 = 1 → 'B'
    //   So 'gB' = 16
    {
        const result = decodeVlq("gB").?;
        try std.testing.expectEqual(@as(i64, 16), result.value);
        try std.testing.expectEqual(@as(usize, 2), result.consumed);
    }
}

test "decodeVlq invalid input" {
    try std.testing.expect(decodeVlq("") == null);
    try std.testing.expect(decodeVlq("!") == null); // invalid base64
}

test "parseLocation basic" {
    // Simple case
    {
        const loc = parseLocation("app.js:10:5").?;
        try std.testing.expectEqualStrings("app.js", loc.file);
        try std.testing.expectEqual(@as(u32, 10), loc.line);
        try std.testing.expectEqual(@as(u32, 5), loc.col);
    }

    // URL with protocol
    {
        const loc = parseLocation("http://example.com/app.js:10:5").?;
        try std.testing.expectEqualStrings("http://example.com/app.js", loc.file);
        try std.testing.expectEqual(@as(u32, 10), loc.line);
        try std.testing.expectEqual(@as(u32, 5), loc.col);
    }
}

test "parseChromeFrame with function name" {
    const frame = parseChromeFrame("at myFunction (http://example.com/app.js:10:5)").?;
    try std.testing.expectEqualStrings("myFunction", frame.function_name.?);
    try std.testing.expectEqualStrings("http://example.com/app.js", frame.file_url);
    try std.testing.expectEqual(@as(u32, 10), frame.line);
    try std.testing.expectEqual(@as(u32, 5), frame.column);
}

test "parseChromeFrame without function name" {
    const frame = parseChromeFrame("at http://example.com/app.js:10:5").?;
    try std.testing.expect(frame.function_name == null);
    try std.testing.expectEqualStrings("http://example.com/app.js", frame.file_url);
    try std.testing.expectEqual(@as(u32, 10), frame.line);
    try std.testing.expectEqual(@as(u32, 5), frame.column);
}

test "parseChromeFrame with new keyword" {
    const frame = parseChromeFrame("at new MyClass (app.js:20:3)").?;
    try std.testing.expectEqualStrings("new MyClass", frame.function_name.?);
    try std.testing.expectEqualStrings("app.js", frame.file_url);
    try std.testing.expectEqual(@as(u32, 20), frame.line);
    try std.testing.expectEqual(@as(u32, 3), frame.column);
}

test "parseFirefoxFrame with function name" {
    const frame = parseFirefoxFrame("myFunction@http://example.com/app.js:10:5").?;
    try std.testing.expectEqualStrings("myFunction", frame.function_name.?);
    try std.testing.expectEqualStrings("http://example.com/app.js", frame.file_url);
    try std.testing.expectEqual(@as(u32, 10), frame.line);
    try std.testing.expectEqual(@as(u32, 5), frame.column);
}

test "parseFirefoxFrame without function name" {
    const frame = parseFirefoxFrame("@http://example.com/app.js:10:5").?;
    try std.testing.expect(frame.function_name == null);
    try std.testing.expectEqualStrings("http://example.com/app.js", frame.file_url);
    try std.testing.expectEqual(@as(u32, 10), frame.line);
    try std.testing.expectEqual(@as(u32, 5), frame.column);
}

test "parseStackTrace Chrome format" {
    const stack =
        \\TypeError: x is not a function
        \\    at myFunction (http://example.com/app.js:10:5)
        \\    at http://example.com/app.js:20:10
    ;

    const frames = try parseStackTrace(std.testing.allocator, stack);
    defer std.testing.allocator.free(frames);

    try std.testing.expectEqual(@as(usize, 2), frames.len);
    try std.testing.expectEqualStrings("myFunction", frames[0].function_name.?);
    try std.testing.expectEqual(@as(u32, 10), frames[0].line);
    try std.testing.expect(frames[1].function_name == null);
    try std.testing.expectEqual(@as(u32, 20), frames[1].line);
}

test "parseStackTrace Firefox format" {
    const stack =
        \\myFunction@http://example.com/app.js:10:5
        \\@http://example.com/app.js:20:10
    ;

    const frames = try parseStackTrace(std.testing.allocator, stack);
    defer std.testing.allocator.free(frames);

    try std.testing.expectEqual(@as(usize, 2), frames.len);
    try std.testing.expectEqualStrings("myFunction", frames[0].function_name.?);
    try std.testing.expectEqual(@as(u32, 10), frames[0].line);
    try std.testing.expect(frames[1].function_name == null);
    try std.testing.expectEqual(@as(u32, 20), frames[1].line);
}

test "normalizeFileUrl strips protocol and domain" {
    try std.testing.expectEqualStrings("/static/app.js", normalizeFileUrl("http://example.com/static/app.js"));
    try std.testing.expectEqualStrings("/static/app.js", normalizeFileUrl("https://example.com/static/app.js"));
    try std.testing.expectEqualStrings("/app.js", normalizeFileUrl("/app.js"));
    try std.testing.expectEqualStrings("app.js", normalizeFileUrl("app.js"));
    try std.testing.expectEqualStrings("/", normalizeFileUrl("http://example.com"));
}

test "parseSourceMap and lookup" {
    // Use arena because parseFromSliceLeaky intentionally leaks parsed JSON data
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_map_json =
        \\{"version": 3, "sources": ["src/app.ts"], "names": [], "mappings": "AAAA"}
    ;

    var sm = try parseSourceMap(alloc, source_map_json);
    defer sm.deinit();

    try std.testing.expectEqual(@as(usize, 1), sm.sources.len);
    try std.testing.expectEqualStrings("src/app.ts", sm.sources[0]);

    const result = sm.lookup(1, 1).?;
    try std.testing.expectEqualStrings("src/app.ts", result.source);
    try std.testing.expectEqual(@as(u32, 1), result.line);
    try std.testing.expectEqual(@as(u32, 1), result.column);
}

test "parseSourceMap multi-line mappings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_map_json =
        \\{"version": 3, "sources": ["src/app.ts"], "names": [], "mappings": "AAAA;AACA"}
    ;

    var sm = try parseSourceMap(alloc, source_map_json);
    defer sm.deinit();

    try std.testing.expectEqual(@as(usize, 2), sm.entries.len);

    const r1 = sm.lookup(1, 1).?;
    try std.testing.expectEqual(@as(u32, 1), r1.line);

    const r2 = sm.lookup(2, 1).?;
    try std.testing.expectEqual(@as(u32, 2), r2.line);
}

test "parseSourceMap with names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_map_json =
        \\{"version": 3, "sources": ["src/app.ts"], "names": ["myFunction"], "mappings": "AAAAA"}
    ;

    var sm = try parseSourceMap(alloc, source_map_json);
    defer sm.deinit();

    const result = sm.lookup(1, 1).?;
    try std.testing.expectEqualStrings("myFunction", result.name.?);
}

test "parseSourceMap with multiple segments on same line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_map_json =
        \\{"version": 3, "sources": ["src/app.ts"], "names": [], "mappings": "AAAA,EACA"}
    ;

    var sm = try parseSourceMap(alloc, source_map_json);
    defer sm.deinit();

    try std.testing.expectEqual(@as(usize, 2), sm.entries.len);

    const r1 = sm.lookup(1, 1).?;
    try std.testing.expectEqual(@as(u32, 1), r1.line);
    try std.testing.expectEqual(@as(u32, 1), r1.column);

    const r2 = sm.lookup(1, 3).?;
    try std.testing.expectEqual(@as(u32, 2), r2.line);
    try std.testing.expectEqual(@as(u32, 1), r2.column);
}

test "SourceMap lookup with column approximation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_map_json =
        \\{"version": 3, "sources": ["src/app.ts"], "names": [], "mappings": "AAAA,KACA"}
    ;

    var sm = try parseSourceMap(alloc, source_map_json);
    defer sm.deinit();

    const r = sm.lookup(1, 4).?;
    try std.testing.expectEqual(@as(u32, 1), r.line);

    const r2 = sm.lookup(1, 7).?;
    try std.testing.expectEqual(@as(u32, 2), r2.line);
}

test "end-to-end: Chrome stack trace deobfuscation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_map_json =
        \\{"version": 3, "sources": ["src/app.ts"], "names": ["handleClick"], "mappings": "AAAAA"}
    ;

    var sm = try parseSourceMap(alloc, source_map_json);
    defer sm.deinit();

    const stack =
        \\TypeError: x is not a function
        \\    at a (/static/app.min.js:1:1)
    ;

    const frames = try parseStackTrace(alloc, stack);

    try std.testing.expectEqual(@as(usize, 1), frames.len);

    const frame = frames[0];
    const file_url = normalizeFileUrl(frame.file_url);
    try std.testing.expectEqualStrings("/static/app.min.js", file_url);

    const result = sm.lookup(frame.line, frame.column).?;
    try std.testing.expectEqualStrings("src/app.ts", result.source);
    try std.testing.expectEqual(@as(u32, 1), result.line);
    try std.testing.expectEqual(@as(u32, 1), result.column);
    try std.testing.expectEqualStrings("handleClick", result.name.?);
}

test "end-to-end: Firefox stack trace deobfuscation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_map_json =
        \\{"version": 3, "sources": ["src/app.ts"], "names": [], "mappings": "AAAA"}
    ;

    var sm = try parseSourceMap(alloc, source_map_json);
    defer sm.deinit();

    const stack =
        \\a@http://example.com/static/app.min.js:1:1
    ;

    const frames = try parseStackTrace(alloc, stack);

    try std.testing.expectEqual(@as(usize, 1), frames.len);

    const file_url = normalizeFileUrl(frames[0].file_url);
    try std.testing.expectEqualStrings("/static/app.min.js", file_url);

    const result = sm.lookup(frames[0].line, frames[0].column).?;
    try std.testing.expectEqualStrings("src/app.ts", result.source);
}
