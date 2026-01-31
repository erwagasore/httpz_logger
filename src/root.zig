//! HTTP request logging middleware for httpz web framework.
//!
//! This middleware automatically logs HTTP requests and responses with configurable
//! formatting, field selection, and performance optimizations.
//!
//! Features:
//! - Multiple output formats (logfmt, JSON)
//! - OpenTelemetry trace context support
//! - Configurable field selection for privacy
//! - Performance optimizations (timestamp caching, smart buffering)
//! - Automatic log level selection based on status codes

const std = @import("std");
const httpz = @import("httpz");

const constants = @import("constants.zig");
const data_extractor = @import("data_extractor.zig");
const json_formatter = @import("formatters/json.zig");
const logfmt_formatter = @import("formatters/logfmt.zig");

// ============================================================================
// Log Level
// ============================================================================

/// Determines the appropriate log level based on HTTP status code.
/// - 5xx errors → .err
/// - 4xx errors → .warn
/// - All others → .info
fn logLevelFromStatus(status: u16) std.log.Level {
    if (status >= 500) return .err;
    if (status >= 400) return .warn;
    return .info;
}

/// Dispatches a log message at the specified level.
fn dispatchLog(level: std.log.Level, message: []const u8) void {
    switch (level) {
        .err => std.log.err("{s}", .{message}),
        .warn => std.log.warn("{s}", .{message}),
        else => std.log.info("{s}", .{message}),
    }
}

/// Output format for log entries.
pub const Format = enum {
    /// JSON format for structured logging systems
    json,
    /// Logfmt format (key=value pairs) for traditional logging
    logfmt,
};

/// Configuration options for the HTTP logger middleware.
pub const Config = struct {
    /// Output format: .json or .logfmt (default: .logfmt)
    format: Format = .logfmt,

    /// Minimum HTTP status code to log (0 = log all)
    min_status: u16 = 0,

    /// Minimum log level to emit (.debug, .info, .warn, .err)
    min_level: std.log.Level = .info,

    /// Include query string in logs (may contain sensitive data)
    log_query: bool = true,

    /// Include User-Agent header
    log_user_agent: bool = true,

    /// Include client IP address and port
    log_client: bool = true,

    /// Include OpenTelemetry trace ID from traceparent header
    log_trace_id: bool = true,

    /// Include OpenTelemetry span ID from traceparent header
    log_span_id: bool = true,

    /// Include X-Request-ID header for request correlation
    log_request_id: bool = true,

    /// Include X-User-ID header for user tracking
    log_user_id: bool = true,

    /// Maximum buffer size for log entries (bytes). Larger logs will be truncated.
    buffer_size: usize = constants.Buffer.DEFAULT_SIZE,

    /// Log formatting/buffer errors to stderr for debugging
    log_errors_to_stderr: bool = true,
};

config: Config,
timestamp_cache: data_extractor.TimestampCache,

/// Initialize a new HTTP logger middleware instance.
///
/// Example:
/// ```zig
/// const logger = try server.middleware(HttpLogger, .{
///     .format = .json,
///     .min_status = 400,  // Only log errors
/// });
/// ```
pub fn init(config: Config) !@This() {
    return .{
        .config = config,
        .timestamp_cache = .{},
    };
}

/// Middleware execution function called by httpz for each request.
/// This function wraps the request handler and logs the response after execution.
pub fn execute(self: *@This(), req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    const start = std.time.milliTimestamp();
    defer self.log(req, res, start);
    return executor.next();
}

fn log(self: *@This(), req: *httpz.Request, res: *httpz.Response, start: i64) void {
    const cfg = self.config;

    if (res.status < cfg.min_status) return;

    const level = logLevelFromStatus(res.status);

    // Filter by minimum log level
    if (@intFromEnum(level) > @intFromEnum(cfg.min_level)) return;

    const data = data_extractor.extractWithCache(req, res, start, .{
        .log_query = cfg.log_query,
        .log_user_agent = cfg.log_user_agent,
        .log_client = cfg.log_client,
        .log_trace_id = cfg.log_trace_id,
        .log_span_id = cfg.log_span_id,
        .log_request_id = cfg.log_request_id,
        .log_user_id = cfg.log_user_id,
    }, &self.timestamp_cache);

    // Stack-allocate buffer up to threshold, heap-allocate for larger sizes
    if (cfg.buffer_size <= constants.Buffer.STACK_THRESHOLD) {
        var stack_buf: [constants.Buffer.STACK_THRESHOLD]u8 = undefined;
        const buf = stack_buf[0..cfg.buffer_size];
        self.formatAndLog(data, level, buf);
    } else {
        // For large buffers, use heap allocation
        const allocator = std.heap.page_allocator;
        const buf = allocator.alloc(u8, cfg.buffer_size) catch {
            if (cfg.log_errors_to_stderr) {
                std.debug.print("httpz_logger: Failed to allocate buffer of size {d}\n", .{cfg.buffer_size});
            }
            return;
        };
        defer allocator.free(buf);
        self.formatAndLog(data, level, buf);
    }
}

fn formatAndLog(self: *const @This(), data: data_extractor.LogData, level: std.log.Level, buf: []u8) void {
    const cfg = self.config;
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    const format_result = switch (cfg.format) {
        .json => json_formatter.formatWriter(data, level, writer),
        .logfmt => logfmt_formatter.formatWriter(data, level, writer),
    };

    if (format_result) |_| {
        const output = stream.getWritten();

        // Check if we hit the buffer limit
        if (stream.pos == buf.len and cfg.log_errors_to_stderr) {
            // Log was likely truncated
            dispatchLog(level, output);
            std.debug.print("httpz_logger: Log entry truncated (buffer size: {d})\n", .{cfg.buffer_size});
        } else {
            dispatchLog(level, output);
        }
    } else |err| {
        if (cfg.log_errors_to_stderr) {
            std.debug.print("httpz_logger: Failed to format log: {}\n", .{err});
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

// Reference submodules to include their inline tests
test {
    _ = @import("constants.zig");
    _ = @import("timestamp.zig");
    _ = @import("data_extractor.zig");
    _ = @import("formatters/json.zig");
    _ = @import("formatters/logfmt.zig");
}

const testing = std.testing;

test "logLevelFromStatus: 5xx returns error" {
    try testing.expectEqual(std.log.Level.err, logLevelFromStatus(500));
    try testing.expectEqual(std.log.Level.err, logLevelFromStatus(503));
    try testing.expectEqual(std.log.Level.err, logLevelFromStatus(599));
}

test "logLevelFromStatus: 4xx returns warn" {
    try testing.expectEqual(std.log.Level.warn, logLevelFromStatus(400));
    try testing.expectEqual(std.log.Level.warn, logLevelFromStatus(404));
    try testing.expectEqual(std.log.Level.warn, logLevelFromStatus(499));
}

test "logLevelFromStatus: 2xx and 3xx returns info" {
    try testing.expectEqual(std.log.Level.info, logLevelFromStatus(200));
    try testing.expectEqual(std.log.Level.info, logLevelFromStatus(201));
    try testing.expectEqual(std.log.Level.info, logLevelFromStatus(301));
    try testing.expectEqual(std.log.Level.info, logLevelFromStatus(304));
}

test "logLevelFromStatus: 1xx returns info" {
    try testing.expectEqual(std.log.Level.info, logLevelFromStatus(100));
    try testing.expectEqual(std.log.Level.info, logLevelFromStatus(101));
}
