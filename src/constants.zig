//! Common constants used throughout the httpz-logger library.
//!
//! This module centralizes magic numbers and configuration defaults
//! to improve maintainability and readability.

const std = @import("std");

/// Time-related constants
pub const Time = struct {
    /// Unix epoch year
    pub const EPOCH_YEAR = 1970;

    /// Maximum supported year for timestamps
    pub const MAX_YEAR = 9999;

    /// Seconds per minute
    pub const SECONDS_PER_MINUTE = 60;

    /// Minutes per hour
    pub const MINUTES_PER_HOUR = 60;

    /// Hours per day
    pub const HOURS_PER_DAY = 24;

    /// Days per non-leap year
    pub const DAYS_PER_YEAR = 365;

    /// Days per leap year
    pub const DAYS_PER_LEAP_YEAR = DAYS_PER_YEAR + 1;

    /// Seconds per hour (derived)
    pub const SECONDS_PER_HOUR = SECONDS_PER_MINUTE * MINUTES_PER_HOUR;

    /// Seconds per day (derived)
    pub const SECONDS_PER_DAY = SECONDS_PER_HOUR * HOURS_PER_DAY;

    /// Returns true if the given year is a leap year.
    pub fn isLeapYear(y: u16) bool {
        return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
    }
};

/// Buffer size constants
pub const Buffer = struct {
    /// Buffer size for log entries (used by thread-local buffer)
    pub const DEFAULT_SIZE = 2048;
};

/// HTTP status code boundaries for log level classification
pub const Status = struct {
    /// Client error threshold (4xx)
    pub const CLIENT_ERROR = @intFromEnum(std.http.Status.bad_request);
    /// Server error threshold (5xx)
    pub const SERVER_ERROR = @intFromEnum(std.http.Status.internal_server_error);
};

/// W3C Traceparent header format constants and validation
/// Format: {version}-{trace_id}-{span_id}-{flags}
pub const Traceparent = struct {
    pub const MIN_LENGTH = 55; // 2 + 1 + 32 + 1 + 16 + 1 + 2
    pub const VERSION = "00";
    pub const VERSION_END = 2;
    pub const TRACE_ID_START = 3;
    pub const TRACE_ID_END = 35;
    pub const SPAN_ID_START = 36;
    pub const SPAN_ID_END = 52;

    pub fn hasValidLength(header: []const u8) bool {
        return header.len >= MIN_LENGTH;
    }

    pub fn hasValidVersion(header: []const u8) bool {
        return std.mem.eql(u8, header[0..VERSION_END], VERSION);
    }

    pub fn hasValidDelimiters(header: []const u8) bool {
        return header[VERSION_END] == '-' and
            header[TRACE_ID_END] == '-' and
            header[SPAN_ID_END] == '-';
    }

    pub fn isValid(header: []const u8) bool {
        return hasValidLength(header) and
            hasValidVersion(header) and
            hasValidDelimiters(header);
    }

    pub fn getTraceId(header: []const u8) []const u8 {
        return header[TRACE_ID_START..TRACE_ID_END];
    }

    pub fn getSpanId(header: []const u8) []const u8 {
        return header[SPAN_ID_START..SPAN_ID_END];
    }
};

// ============================================================================
// Compile-time Validation
// ============================================================================

comptime {
    // Ensure buffer size is a power of 2 for alignment
    std.debug.assert(@popCount(@as(u32, Buffer.DEFAULT_SIZE)) == 1);

    // Ensure time constants are positive
    std.debug.assert(Time.SECONDS_PER_DAY > 0);
    std.debug.assert(Time.DAYS_PER_YEAR > 0);
    std.debug.assert(Time.EPOCH_YEAR > 0);
    std.debug.assert(Time.MAX_YEAR > Time.EPOCH_YEAR);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const valid_header = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";

test "Traceparent.hasValidLength" {
    // valid length
    try testing.expect(Traceparent.hasValidLength(valid_header));
    // exactly 55 chars
    try testing.expect(Traceparent.hasValidLength(valid_header[0..55]));
    // too short
    try testing.expect(!Traceparent.hasValidLength("00-abc-def-01"));
    // empty
    try testing.expect(!Traceparent.hasValidLength(""));
}

test "Traceparent.hasValidVersion" {
    // valid version 00
    try testing.expect(Traceparent.hasValidVersion(valid_header));
    // invalid version 01
    const v01 = "01-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
    try testing.expect(!Traceparent.hasValidVersion(v01));
    // invalid version ff
    const vff = "ff-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
    try testing.expect(!Traceparent.hasValidVersion(vff));
}

test "Traceparent.hasValidDelimiters" {
    // valid delimiters
    try testing.expect(Traceparent.hasValidDelimiters(valid_header));
    // underscores instead of dashes
    const underscores = "00_0af7651916cd43dd8448eb211c80319c_b7ad6b7169203331_01";
    try testing.expect(!Traceparent.hasValidDelimiters(underscores));
}

test "Traceparent.isValid" {
    try testing.expect(Traceparent.isValid(valid_header));
    try testing.expect(!Traceparent.isValid("invalid"));
}

test "Traceparent.getTraceId" {
    const trace_id = Traceparent.getTraceId(valid_header);
    try testing.expectEqualStrings("0af7651916cd43dd8448eb211c80319c", trace_id);
}

test "Traceparent.getSpanId" {
    const span_id = Traceparent.getSpanId(valid_header);
    try testing.expectEqualStrings("b7ad6b7169203331", span_id);
}
