const std = @import("std");

/// Determines the appropriate log level based on HTTP status code.
/// - 5xx errors → .err
/// - 4xx errors → .warn
/// - All others → .info
pub fn fromStatus(status: u16) std.log.Level {
    if (status >= 500) return .err;
    if (status >= 400) return .warn;
    return .info;
}

/// Dispatches a log message at the specified level.
pub fn dispatch(level: std.log.Level, message: []const u8) void {
    switch (level) {
        .err => std.log.err("{s}", .{message}),
        .warn => std.log.warn("{s}", .{message}),
        else => std.log.info("{s}", .{message}),
    }
}

const testing = std.testing;

test "5xx returns error" {
    try testing.expectEqual(std.log.Level.err, fromStatus(500));
    try testing.expectEqual(std.log.Level.err, fromStatus(503));
    try testing.expectEqual(std.log.Level.err, fromStatus(599));
}

test "4xx returns warn" {
    try testing.expectEqual(std.log.Level.warn, fromStatus(400));
    try testing.expectEqual(std.log.Level.warn, fromStatus(404));
    try testing.expectEqual(std.log.Level.warn, fromStatus(499));
}

test "2xx and 3xx returns info" {
    try testing.expectEqual(std.log.Level.info, fromStatus(200));
    try testing.expectEqual(std.log.Level.info, fromStatus(201));
    try testing.expectEqual(std.log.Level.info, fromStatus(301));
    try testing.expectEqual(std.log.Level.info, fromStatus(304));
}

test "1xx returns info" {
    try testing.expectEqual(std.log.Level.info, fromStatus(100));
    try testing.expectEqual(std.log.Level.info, fromStatus(101));
}
