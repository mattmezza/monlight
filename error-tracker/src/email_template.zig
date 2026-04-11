const std = @import("std");

/// Stable boundary marker for multipart/alternative bodies emitted by this
/// module. Picked to be highly unlikely to appear inside an HTML or plain
/// text body. RFC 2046 §5.1.1 only requires the boundary to not appear in
/// any encapsulated body part — we do not attempt boundary collision
/// detection because the chance of accidentally producing this exact
/// 19-character token in either rendered form is negligible.
pub const mime_boundary = "=_mlmp_b1a8e7c4f9d2_=";

/// Header value to set on the outer message envelope when sending a body
/// produced by this module.
pub const multipart_content_type = "multipart/alternative; boundary=\"" ++ mime_boundary ++ "\"";

/// Maximum traceback bytes embedded in either part. Anything past this is
/// dropped with a `[traceback truncated]` marker so that the message body
/// stays well under typical SMTP / email-client size limits.
const max_traceback_bytes: usize = 12 * 1024;

pub const ErrorParams = struct {
    project: []const u8,
    exception_type: []const u8,
    message: []const u8,
    traceback: []const u8,
    request_method: ?[]const u8,
    request_url: ?[]const u8,
    error_id: i64,
    base_url: []const u8,
};

/// Build a complete `multipart/alternative` MIME body (text + html) for an
/// error alert. The returned slice is owned by the caller and must be freed
/// with the same allocator. Both parts include the error id and the
/// `/errors/{id}` deep-link so recipients can disambiguate alerts.
pub fn buildErrorAlertMessage(allocator: std.mem.Allocator, p: ErrorParams) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try writePartHeader(w, "text/plain; charset=utf-8");
    try writePlainErrorBody(w, p);
    try w.writeAll("\r\n");

    try writePartHeader(w, "text/html; charset=utf-8");
    try writeHtmlErrorBody(w, p);
    try w.writeAll("\r\n");

    try writeClosingBoundary(w);

    return try buf.toOwnedSlice(allocator);
}

/// Build a complete `multipart/alternative` MIME body for the SMTP test
/// alert. Same shape as the error alert so operators can verify both parts
/// of the email render correctly in their inbox.
pub fn buildTestAlertMessage(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try writePartHeader(w, "text/plain; charset=utf-8");
    try writePlainTestBody(w, base_url);
    try w.writeAll("\r\n");

    try writePartHeader(w, "text/html; charset=utf-8");
    try writeHtmlTestBody(w, base_url);
    try w.writeAll("\r\n");

    try writeClosingBoundary(w);

    return try buf.toOwnedSlice(allocator);
}

fn writePartHeader(w: anytype, content_type: []const u8) !void {
    try w.writeAll("--" ++ mime_boundary ++ "\r\n");
    try w.print("Content-Type: {s}\r\n", .{content_type});
    try w.writeAll("Content-Transfer-Encoding: 8bit\r\n\r\n");
}

fn writeClosingBoundary(w: anytype) !void {
    try w.writeAll("--" ++ mime_boundary ++ "--\r\n");
}

// --- Plain text bodies ---

fn writePlainErrorBody(w: anytype, p: ErrorParams) !void {
    try w.print("New error in {s}\r\n\r\n", .{p.project});
    try w.print("Error ID:  #{d}\r\n", .{p.error_id});
    try w.print("Detail:    /errors/{d}\r\n", .{p.error_id});
    try w.print("Link:      {s}/errors/{d}\r\n\r\n", .{ p.base_url, p.error_id });
    try w.print("Exception: {s}\r\n", .{p.exception_type});
    try w.print("Message:   {s}\r\n", .{p.message});
    if (p.request_method != null and p.request_url != null) {
        try w.print("Request:   {s} {s}\r\n", .{ p.request_method.?, p.request_url.? });
    }
    try w.writeAll("\r\nTraceback:\r\n");
    try writePlainTracebackTruncated(w, p.traceback);
    try w.writeAll("\r\n---\r\nView in Error Tracker:\r\n");
    try w.print("{s}/errors/{d}\r\n", .{ p.base_url, p.error_id });
}

fn writePlainTestBody(w: anytype, base_url: []const u8) !void {
    try w.writeAll("This is a test alert from the Error Tracker.\r\n\r\n");
    try w.writeAll("If you received this email, your SMTP configuration is working correctly.\r\n\r\n");
    try w.writeAll("---\r\n");
    try w.print("Dashboard: {s}\r\n", .{base_url});
}

/// Copy `s` to the writer normalising any line ending to CRLF and stopping
/// after `max_traceback_bytes`. Appends a `[traceback truncated]` marker if
/// the input was clipped.
fn writePlainTracebackTruncated(w: anytype, s: []const u8) !void {
    const text = if (s.len > max_traceback_bytes) s[0..max_traceback_bytes] else s;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        switch (c) {
            '\n' => try w.writeAll("\r\n"),
            '\r' => {}, // dropped — paired '\n' will emit CRLF
            else => try w.writeByte(c),
        }
    }
    if (s.len > max_traceback_bytes) {
        try w.writeAll("\r\n[traceback truncated]\r\n");
    }
}

// --- HTML bodies ---

fn writeHtmlErrorBody(w: anytype, p: ErrorParams) !void {
    try w.writeAll(html_doc_open);
    try w.writeAll(html_card_open);

    // Banner
    try w.writeAll("<tr><td style=\"padding:24px 28px 22px 28px; background-color:#dc2626; color:#ffffff; border-top-left-radius:8px; border-top-right-radius:8px;\">");
    try w.writeAll("<div style=\"font-size:11px; font-weight:700; letter-spacing:0.08em; text-transform:uppercase; opacity:0.9;\">New error &middot; ");
    try writeHtmlEscaped(w, p.project);
    try w.writeAll("</div>");
    try w.writeAll("<div style=\"font-size:22px; font-weight:700; margin-top:6px; word-break:break-word;\">");
    try writeHtmlEscaped(w, p.exception_type);
    try w.writeAll("</div>");
    try w.writeAll("<div style=\"font-size:14px; line-height:1.5; margin-top:8px; opacity:0.95; word-break:break-word; white-space:pre-wrap;\">");
    try writeHtmlEscaped(w, p.message);
    try w.writeAll("</div>");
    try w.writeAll("</td></tr>");

    // Error id row
    try w.writeAll("<tr><td style=\"padding:18px 28px 6px 28px;\">");
    try writeMetaLabel(w, "Error ID");
    try w.writeAll("<div style=\"font-family:'SFMono-Regular',Menlo,Monaco,Consolas,monospace; font-size:13px; color:#1f2937; margin-top:4px;\">");
    try w.print("#{d}", .{p.error_id});
    try w.writeAll(" <span style=\"color:#9ca3af;\">&middot;</span> <span style=\"color:#6b7280;\">/errors/");
    try w.print("{d}", .{p.error_id});
    try w.writeAll("</span></div>");
    try w.writeAll("</td></tr>");

    // Request row
    if (p.request_method != null and p.request_url != null) {
        try w.writeAll("<tr><td style=\"padding:10px 28px 6px 28px;\">");
        try writeMetaLabel(w, "Request");
        try w.writeAll("<div style=\"font-family:'SFMono-Regular',Menlo,Monaco,Consolas,monospace; font-size:13px; color:#1f2937; margin-top:4px; word-break:break-all;\">");
        try w.writeAll("<span style=\"display:inline-block; padding:2px 8px; background:#eef2ff; color:#4338ca; border-radius:4px; font-weight:700; font-size:11px; margin-right:6px; vertical-align:middle;\">");
        try writeHtmlEscaped(w, p.request_method.?);
        try w.writeAll("</span>");
        try writeHtmlEscaped(w, p.request_url.?);
        try w.writeAll("</div>");
        try w.writeAll("</td></tr>");
    }

    // Traceback
    try w.writeAll("<tr><td style=\"padding:18px 28px 8px 28px;\">");
    try writeMetaLabel(w, "Traceback");
    try w.writeAll("<pre style=\"margin:8px 0 0 0; padding:14px 16px; background:#0f172a; color:#e2e8f0; border-radius:6px; font-family:'SFMono-Regular',Menlo,Monaco,Consolas,monospace; font-size:12px; line-height:1.5; white-space:pre; overflow-x:auto;\">");
    try writeHtmlTracebackTruncated(w, p.traceback);
    try w.writeAll("</pre>");
    try w.writeAll("</td></tr>");

    // CTA
    try w.writeAll("<tr><td style=\"padding:22px 28px 26px 28px;\">");
    try w.writeAll("<a href=\"");
    try writeHtmlAttrEscaped(w, p.base_url);
    try w.print("/errors/{d}", .{p.error_id});
    try w.writeAll("\" style=\"display:inline-block; padding:12px 22px; background:#1f2937; color:#ffffff; text-decoration:none; border-radius:6px; font-size:14px; font-weight:600;\">View error details &rarr;</a>");
    try w.writeAll("</td></tr>");

    // Footer
    try w.writeAll("<tr><td style=\"padding:14px 28px 22px 28px; border-top:1px solid #f1f5f9; font-size:11px; color:#9ca3af;\">");
    try w.writeAll("Sent by Error Tracker. You're receiving this because your address is listed in <code style=\"background:#f3f4f6; padding:1px 5px; border-radius:3px; color:#6b7280;\">ALERT_EMAILS</code>.");
    try w.writeAll("</td></tr>");

    try w.writeAll(html_card_close);
    try w.writeAll(html_doc_close);
}

fn writeHtmlTestBody(w: anytype, base_url: []const u8) !void {
    try w.writeAll(html_doc_open);
    try w.writeAll(html_card_open);

    try w.writeAll("<tr><td style=\"padding:24px 28px 22px 28px; background-color:#10b981; color:#ffffff; border-top-left-radius:8px; border-top-right-radius:8px;\">");
    try w.writeAll("<div style=\"font-size:11px; font-weight:700; letter-spacing:0.08em; text-transform:uppercase; opacity:0.9;\">SMTP test</div>");
    try w.writeAll("<div style=\"font-size:22px; font-weight:700; margin-top:6px;\">It works!</div>");
    try w.writeAll("</td></tr>");

    try w.writeAll("<tr><td style=\"padding:22px 28px; font-size:14px; line-height:1.55; color:#374151;\">");
    try w.writeAll("This is a test alert from the Error Tracker. If you received this email and the layout above renders correctly, your SMTP configuration and your client's HTML rendering are both working.");
    try w.writeAll("</td></tr>");

    try w.writeAll("<tr><td style=\"padding:0 28px 26px 28px;\">");
    try w.writeAll("<a href=\"");
    try writeHtmlAttrEscaped(w, base_url);
    try w.writeAll("\" style=\"display:inline-block; padding:12px 22px; background:#1f2937; color:#ffffff; text-decoration:none; border-radius:6px; font-size:14px; font-weight:600;\">Open dashboard &rarr;</a>");
    try w.writeAll("</td></tr>");

    try w.writeAll(html_card_close);
    try w.writeAll(html_doc_close);
}

fn writeMetaLabel(w: anytype, label: []const u8) !void {
    try w.writeAll("<div style=\"font-size:10px; font-weight:700; color:#6b7280; text-transform:uppercase; letter-spacing:0.06em;\">");
    try w.writeAll(label);
    try w.writeAll("</div>");
}

const html_doc_open: []const u8 =
    "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Transitional//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd\">\r\n" ++
    "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head>" ++
    "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\" />" ++
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\" />" ++
    "<title>Error Tracker</title>" ++
    "</head>" ++
    "<body style=\"margin:0; padding:0; background-color:#f4f5f7; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif; color:#1f2937;\">" ++
    "<table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" width=\"100%\" style=\"background-color:#f4f5f7;\"><tr><td align=\"center\" style=\"padding:24px 12px;\">";

const html_doc_close: []const u8 =
    "</td></tr></table></body></html>";

const html_card_open: []const u8 =
    "<table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" width=\"640\" style=\"max-width:640px; width:100%; background-color:#ffffff; border-radius:8px; border:1px solid #e5e7eb;\">";

const html_card_close: []const u8 =
    "</table>";

fn writeHtmlEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            else => try w.writeByte(c),
        }
    }
}

fn writeHtmlAttrEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&#39;"),
            else => try w.writeByte(c),
        }
    }
}

/// HTML-escape `s` and copy it into the writer, normalising any line ending
/// to CRLF and stopping after `max_traceback_bytes`. Appends a marker line if
/// the source was clipped.
fn writeHtmlTracebackTruncated(w: anytype, s: []const u8) !void {
    const text = if (s.len > max_traceback_bytes) s[0..max_traceback_bytes] else s;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        switch (c) {
            '\n' => try w.writeAll("\r\n"),
            '\r' => {},
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            else => try w.writeByte(c),
        }
    }
    if (s.len > max_traceback_bytes) {
        try w.writeAll("\r\n[traceback truncated]\r\n");
    }
}

// --- Tests ---

test "buildErrorAlertMessage emits both parts and the error id link" {
    const params = ErrorParams{
        .project = "demo",
        .exception_type = "IndexError",
        .message = "tuple index out of range",
        .traceback = "Traceback (most recent call last):\n  File \"x.py\", line 1, in <module>\n    pass\nIndexError: tuple index out of range\n",
        .request_method = "GET",
        .request_url = "https://example.test/items",
        .error_id = 42,
        .base_url = "http://localhost:5010",
    };

    const body = try buildErrorAlertMessage(std.testing.allocator, params);
    defer std.testing.allocator.free(body);

    // Both MIME parts present
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Type: text/plain; charset=utf-8") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Type: text/html; charset=utf-8") != null);
    // Boundary opens twice and closes once
    try std.testing.expect(std.mem.indexOf(u8, body, "--" ++ mime_boundary ++ "--") != null);
    // Error id appears in both forms
    try std.testing.expect(std.mem.indexOf(u8, body, "#42") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "/errors/42") != null);
    // Plain text body fields
    try std.testing.expect(std.mem.indexOf(u8, body, "Exception: IndexError") != null);
    // HTML body shell
    try std.testing.expect(std.mem.indexOf(u8, body, "<!DOCTYPE html") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "</html>") != null);
}

test "html escaping covers angle brackets and ampersands" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try writeHtmlEscaped(buf.writer(std.testing.allocator), "<a&b>");
    try std.testing.expectEqualStrings("&lt;a&amp;b&gt;", buf.items);
}

test "html attr escaping also escapes quotes" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try writeHtmlAttrEscaped(buf.writer(std.testing.allocator), "x\"y'z");
    try std.testing.expectEqualStrings("x&quot;y&#39;z", buf.items);
}

test "plain traceback truncation appends marker" {
    var long_buf: [max_traceback_bytes + 100]u8 = undefined;
    @memset(&long_buf, 'x');
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try writePlainTracebackTruncated(buf.writer(std.testing.allocator), long_buf[0..]);
    try std.testing.expect(std.mem.endsWith(u8, buf.items, "[traceback truncated]\r\n"));
}

test "buildTestAlertMessage produces multipart body" {
    const body = try buildTestAlertMessage(std.testing.allocator, "http://localhost:5010");
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Type: text/plain") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Type: text/html") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "It works!") != null);
}
