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
const Buffer = constants.Buffer;
const Status = constants.Status;

const data_extractor = @import("data_extractor.zig");

/// Thread-local buffer for zero-allocation logging.
/// Each thread gets its own buffer - no locks, no contention.
threadlocal var log_buffer: [Buffer.DEFAULT_SIZE]u8 = undefined;

/// Large fallback buffer used when primary buffer is exhausted.
/// Only accessed when a log entry exceeds DEFAULT_SIZE bytes.
threadlocal var large_log_buffer: [Buffer.LARGE_SIZE]u8 = undefined;

// ============================================================================
// Log Level
// ============================================================================

/// Determines the appropriate log level based on HTTP status code.
/// - 5xx errors → .err
/// - 4xx errors → .warn
/// - All others → .info
fn logLevelFromStatus(status: u16) std.log.Level {
    if (status >= Status.SERVER_ERROR) return .err;
    if (status >= Status.CLIENT_ERROR) return .warn;
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

    self.formatAndLog(data, level);
}

/// Formats and logs using tiered buffers: tries 2KB first, falls back to 8KB.
fn formatAndLog(self: *const @This(), data: data_extractor.LogData, level: std.log.Level) void {
    // Try primary buffer (2KB) - handles 99% of logs
    if (self.tryFormat(data, level, &log_buffer)) |output| {
        dispatchLog(level, output);
        return;
    }

    // Try large buffer (8KB) - handles oversized logs
    if (self.tryFormat(data, level, &large_log_buffer)) |output| {
        dispatchLog(level, output);
        return;
    }

    // Both buffers exhausted - output truncated with warning
    self.logTruncated(data, level);
}

/// Attempts to format into buffer. Returns written slice on success, null if buffer exhausted.
fn tryFormat(self: *const @This(), data: data_extractor.LogData, level: std.log.Level, buf: []u8) ?[]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    const result = switch (self.config.format) {
        .json => data.toJson(level, writer),
        .logfmt => data.toLogfmt(level, writer),
    };

    if (result) |_| {
        // Buffer full = likely truncated, try larger buffer
        if (stream.pos == buf.len) return null;
        return stream.getWritten();
    } else |err| {
        if (err == error.NoSpaceLeft) return null;
        if (self.config.log_errors_to_stderr) {
            std.debug.print("httpz_logger: Failed to format log: {}\n", .{err});
        }
        return stream.getWritten(); // Return partial on other errors
    }
}

/// Outputs truncated log with warning to stderr.
fn logTruncated(self: *const @This(), data: data_extractor.LogData, level: std.log.Level) void {
    var stream = std.io.fixedBufferStream(&large_log_buffer);
    _ = switch (self.config.format) {
        .json => data.toJson(level, stream.writer()),
        .logfmt => data.toLogfmt(level, stream.writer()),
    } catch {};

    const output = stream.getWritten();
    if (output.len > 0) dispatchLog(level, output);

    if (self.config.log_errors_to_stderr) {
        std.debug.print("httpz_logger: Log truncated (exceeded {d}B, fallback {d}B exhausted)\n", .{
            Buffer.DEFAULT_SIZE,
            Buffer.LARGE_SIZE,
        });
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
}

const testing = std.testing;

test "logLevelFromStatus" {
    // 5xx returns error
    try testing.expectEqual(std.log.Level.err, logLevelFromStatus(500));
    try testing.expectEqual(std.log.Level.err, logLevelFromStatus(503));
    try testing.expectEqual(std.log.Level.err, logLevelFromStatus(599));

    // 4xx returns warn
    try testing.expectEqual(std.log.Level.warn, logLevelFromStatus(400));
    try testing.expectEqual(std.log.Level.warn, logLevelFromStatus(404));
    try testing.expectEqual(std.log.Level.warn, logLevelFromStatus(499));

    // 2xx and 3xx returns info
    try testing.expectEqual(std.log.Level.info, logLevelFromStatus(200));
    try testing.expectEqual(std.log.Level.info, logLevelFromStatus(201));
    try testing.expectEqual(std.log.Level.info, logLevelFromStatus(301));
    try testing.expectEqual(std.log.Level.info, logLevelFromStatus(304));

    // 1xx returns info
    try testing.expectEqual(std.log.Level.info, logLevelFromStatus(100));
    try testing.expectEqual(std.log.Level.info, logLevelFromStatus(101));
}
