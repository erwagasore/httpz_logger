const std = @import("std");
const data_extractor = @import("../data_extractor.zig");

/// Formats log data as JSON.
pub fn format(data: data_extractor.LogData, level: std.log.Level, writer: *std.Io.Writer) !void {
    const client = data.client();

    var jw: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    try jw.write(.{
        .timestamp = data.timestamp(),
        .level = @tagName(level),
        .trace_id = data.trace_id,
        .span_id = data.span_id,
        .method = @tagName(data.method),
        .client = if (client.len > 0) client else null,
        .path = data.path,
        .query = data.query,
        .status = data.status,
        .size = data.size,
        .duration_ms = data.duration_ms,
        .user_agent = data.user_agent,
        .user_id = data.user_id,
        .request_id = data.request_id,
    });
}
