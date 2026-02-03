const std = @import("std");
const httpz = @import("httpz");

const constants = @import("constants.zig");
const Traceparent = constants.Traceparent;
const Timestamp = @import("timestamp.zig");

/// Parses W3C traceparent header: 00-<trace_id>-<span_id>-<flags>
/// Returns trace_id (32 hex chars) and span_id (16 hex chars) slices.
/// Only supports version 00. Future versions may have different formats.
pub fn parseTraceparent(header: []const u8) ?struct {
    trace_id: []const u8,
    span_id: []const u8,
} {
    if (!Traceparent.isValid(header)) return null;

    return .{
        .trace_id = Traceparent.getTraceId(header),
        .span_id = Traceparent.getSpanId(header),
    };
}

pub const LogData = struct {
    timestamp_buf: [20]u8 = undefined,
    address_buf: [24]u8 = undefined,
    address_len: usize = 0,
    trace_id: ?[]const u8 = null,
    span_id: ?[]const u8 = null,
    method: httpz.Method,
    path: []const u8,
    query: ?[]const u8,
    status: u16,
    size: usize,
    duration_ms: i64,
    user_agent: ?[]const u8,
    user_id: ?[]const u8,
    request_id: ?[]const u8,

    pub fn timestamp(self: *const LogData) []const u8 {
        return &self.timestamp_buf;
    }

    pub fn client(self: *const LogData) []const u8 {
        return self.address_buf[0..self.address_len];
    }

    /// Formats client address into the internal buffer.
    pub fn formatClient(self: *LogData, address: httpz.Address) void {
        var writer: std.Io.Writer = .fixed(&self.address_buf);
        address.in.format(&writer) catch {};
        self.address_len = writer.end;
    }

    /// Formats current timestamp as ISO 8601 into the internal buffer.
    pub fn formatTimestamp(self: *LogData) void {
        var ts = Timestamp.now();
        _ = ts.iso8601(&self.timestamp_buf);
    }

    /// Formats as JSON using std.json.stringify
    pub fn toJson(self: *const LogData, level: std.log.Level, writer: anytype) !void {
        const client_addr = self.client();
        try std.json.stringify(.{
            .timestamp = self.timestamp(),
            .level = @tagName(level),
            .method = @tagName(self.method),
            .path = self.path,
            .query = self.query,
            .status = self.status,
            .size = self.size,
            .duration_ms = self.duration_ms,
            .client = if (client_addr.len > 0) client_addr else null,
            .trace_id = self.trace_id,
            .span_id = self.span_id,
            .user_agent = self.user_agent,
            .user_id = self.user_id,
            .request_id = self.request_id,
        }, .{ .emit_null_optional_fields = false }, writer);
    }

    /// Formats as logfmt (key=value pairs) for terminal display
    pub fn toLogfmt(self: *const LogData, level: std.log.Level, writer: anytype) !void {
        try writer.print("timestamp=", .{});
        try writeLogfmtValue(writer, self.timestamp());
        try writer.print(" level={s} method={s} path=", .{ @tagName(level), @tagName(self.method) });
        try writeLogfmtValue(writer, self.path);
        try writer.print(" status={d} size={d} duration_ms={d}", .{ self.status, self.size, self.duration_ms });
        const client_addr = self.client();
        if (client_addr.len > 0) try writeLogfmtField(writer, "client", client_addr);
        if (self.trace_id) |v| try writeLogfmtField(writer, "trace_id", v);
        if (self.span_id) |v| try writeLogfmtField(writer, "span_id", v);
        if (self.query) |v| try writeLogfmtField(writer, "query", v);
        if (self.user_agent) |v| try writeLogfmtField(writer, "user_agent", v);
        if (self.user_id) |v| try writeLogfmtField(writer, "user_id", v);
        if (self.request_id) |v| try writeLogfmtField(writer, "request_id", v);
    }
};

fn needsLogfmtQuoting(value: []const u8) bool {
    if (value.len == 0) return true;
    for (value) |c| {
        if (c == ' ' or c == '=' or c == '"' or c == '\\') return true;
        if (c < 0x20 or c == 0x7f) return true;
    }
    return false;
}

fn writeLogfmtValue(writer: anytype, value: []const u8) !void {
    if (!needsLogfmtQuoting(value)) {
        try writer.writeAll(value);
        return;
    }

    try writer.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20 or c == 0x7f) {
                    try writer.print("\\x{x:0>2}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn writeLogfmtField(writer: anytype, key: []const u8, value: []const u8) !void {
    try writer.print(" {s}=", .{key});
    try writeLogfmtValue(writer, value);
}

pub const ExtractConfig = struct {
    log_query: bool = true,
    log_user_agent: bool = true,
    log_client: bool = true,
    log_trace_id: bool = true,
    log_span_id: bool = true,
    log_request_id: bool = true,
    log_user_id: bool = true,
};

/// Extracts log data from request/response with timing information.
pub fn extract(
    req: *httpz.Request,
    res: *httpz.Response,
    start: i64,
    config: ExtractConfig,
) LogData {
    const traceparent = req.header("traceparent");
    const trace_ctx = if (config.log_trace_id or config.log_span_id)
        if (traceparent) |tp| parseTraceparent(tp) else null
    else
        null;

    var data: LogData = .{
        .trace_id = if (config.log_trace_id and trace_ctx != null)
            trace_ctx.?.trace_id
        else
            null,
        .span_id = if (config.log_span_id and trace_ctx != null)
            trace_ctx.?.span_id
        else
            null,
        .method = req.method,
        .path = req.url.path,
        .query = if (config.log_query and req.url.query.len > 0)
            req.url.query
        else
            null,
        .status = res.status,
        .size = res.body.len,
        .duration_ms = std.time.milliTimestamp() - start,
        .user_agent = if (config.log_user_agent)
            req.header("user-agent")
        else
            null,
        .user_id = if (config.log_user_id)
            req.header("x-user-id") orelse req.header("x-user")
        else
            null,
        .request_id = if (config.log_request_id)
            req.header("x-request-id")
        else
            null,
    };

    if (config.log_client) {
        data.formatClient(req.address);
    }

    return data;
}

const testing = std.testing;

test "parseTraceparent" {
    // valid header returns trace_id and span_id
    const header = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
    const result = parseTraceparent(header);
    try testing.expect(result != null);
    try testing.expectEqualStrings("0af7651916cd43dd8448eb211c80319c", result.?.trace_id);
    try testing.expectEqualStrings("b7ad6b7169203331", result.?.span_id);

    // invalid header returns null
    try testing.expect(parseTraceparent("invalid") == null);
}

test "toLogfmt escapes and quotes values" {
    var data: LogData = .{
        .method = .GET,
        .path = "/hello world",
        .query = "a=1 b=2",
        .status = 200,
        .size = 0,
        .duration_ms = 5,
        .user_agent = "curl/8.0",
        .user_id = "user\"x",
        .request_id = "req\\id",
        .trace_id = "0af7651916cd43dd8448eb211c80319c",
        .span_id = "b7ad6b7169203331",
    };

    const ts = "2025-01-01T00:00:00Z";
    @memcpy(&data.timestamp_buf, ts);

    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try data.toLogfmt(.info, stream.writer());

    const expected =
        "timestamp=2025-01-01T00:00:00Z level=info method=GET path=\"/hello world\" status=200 size=0 duration_ms=5" ++
        " trace_id=0af7651916cd43dd8448eb211c80319c span_id=b7ad6b7169203331" ++
        " query=\"a=1 b=2\" user_agent=curl/8.0 user_id=\"user\\\"x\" request_id=\"req\\\\id\"";
    try testing.expectEqualStrings(expected, stream.getWritten());
}

test "toLogfmt includes client and handles empty values" {
    var data: LogData = .{
        .method = .POST,
        .path = "/api",
        .query = "", // empty string should be quoted
        .status = 201,
        .size = 42,
        .duration_ms = 10,
        .user_agent = null,
        .user_id = null,
        .request_id = null,
        .trace_id = null,
        .span_id = null,
    };

    const ts = "2025-01-01T00:00:00Z";
    @memcpy(&data.timestamp_buf, ts);

    // Set client address
    const client_ip = "192.168.1.100";
    @memcpy(data.address_buf[0..client_ip.len], client_ip);
    data.address_len = client_ip.len;

    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try data.toLogfmt(.warn, stream.writer());

    const expected =
        "timestamp=2025-01-01T00:00:00Z level=warn method=POST path=/api status=201 size=42 duration_ms=10" ++
        " client=192.168.1.100 query=\"\"";
    try testing.expectEqualStrings(expected, stream.getWritten());
}

test "toLogfmt escapes control characters" {
    var data: LogData = .{
        .method = .GET,
        .path = "/test",
        .query = null,
        .status = 200,
        .size = 0,
        .duration_ms = 1,
        .user_agent = "bot\x00\x1f\x7f", // null, unit separator, DEL
        .user_id = null,
        .request_id = null,
        .trace_id = null,
        .span_id = null,
    };

    const ts = "2025-01-01T00:00:00Z";
    @memcpy(&data.timestamp_buf, ts);

    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try data.toLogfmt(.info, stream.writer());

    const expected =
        "timestamp=2025-01-01T00:00:00Z level=info method=GET path=/test status=200 size=0 duration_ms=1" ++
        " user_agent=\"bot\\x00\\x1f\\x7f\"";
    try testing.expectEqualStrings(expected, stream.getWritten());
}
