const std = @import("std");
const constants = @import("constants.zig");
const Time = constants.Time;

const Self = @This();

/// Days in each month (non-leap year)
const DAYS_IN_MONTH = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

timestamp: i64,

// Cached date components (computed once)
cached_year: u16 = 0,
cached_day_of_year: u16 = 0,
cached: bool = false,

pub fn now() Self {
    return .{ .timestamp = std.time.timestamp() };
}

pub fn init(ts: i64) Self {
    return .{ .timestamp = ts };
}

/// Formats timestamp as ISO 8601: "YYYY-MM-DDTHH:MM:SSZ"
pub fn iso8601(self: *Self, buf: *[20]u8) []const u8 {
    self.ensureCached();
    const md = monthAndDay(self.cached_year, self.cached_day_of_year);

    _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        self.cached_year,
        md.month,
        md.day,
        self.hour(),
        self.minute(),
        self.second(),
    }) catch unreachable;
    return buf;
}

pub fn year(self: *Self) u16 {
    self.ensureCached();
    return self.cached_year;
}

pub fn month(self: *Self) u8 {
    self.ensureCached();
    return monthAndDay(self.cached_year, self.cached_day_of_year).month;
}

pub fn dayOfMonth(self: *Self) u8 {
    self.ensureCached();
    return monthAndDay(self.cached_year, self.cached_day_of_year).day;
}

pub fn dayOfYear(self: *Self) u16 {
    self.ensureCached();
    return self.cached_day_of_year;
}

pub fn hour(self: *const Self) u8 {
    return @intCast(@mod(@divFloor(self.timestamp, Time.SECONDS_PER_HOUR), Time.HOURS_PER_DAY));
}

pub fn minute(self: *const Self) u8 {
    return @intCast(@mod(@divFloor(self.timestamp, Time.SECONDS_PER_MINUTE), Time.MINUTES_PER_HOUR));
}

pub fn second(self: *const Self) u8 {
    return @intCast(@mod(self.timestamp, Time.SECONDS_PER_MINUTE));
}

pub fn daysSinceEpoch(self: *const Self) i64 {
    return @divFloor(self.timestamp, Time.SECONDS_PER_DAY);
}

fn ensureCached(self: *Self) void {
    if (self.cached) return;

    var remaining = self.daysSinceEpoch();

    // Handle dates before Unix epoch (1970)
    if (remaining < 0) {
        // Clamp to minimum valid date
        self.cached_year = Time.EPOCH_YEAR;
        self.cached_day_of_year = 1;
        self.cached = true;
        return;
    }

    // Handle dates after reasonable maximum (year 9999)
    if (remaining > Time.DAYS_PER_YEAR * (Time.MAX_YEAR - Time.EPOCH_YEAR)) {
        self.cached_year = Time.MAX_YEAR;
        self.cached_day_of_year = Time.DAYS_PER_YEAR;
        self.cached = true;
        return;
    }

    var y: u16 = Time.EPOCH_YEAR;
    while (true) {
        const days_in_year: i64 = if (Time.isLeapYear(y)) Time.DAYS_PER_LEAP_YEAR else Time.DAYS_PER_YEAR;
        if (remaining < days_in_year) break;
        remaining -= days_in_year;
        y += 1;
        if (y > Time.MAX_YEAR) {
            // Prevent overflow
            y = Time.MAX_YEAR;
            break;
        }
    }

    self.cached_year = y;
    self.cached_day_of_year = @intCast(@max(1, @min(Time.DAYS_PER_LEAP_YEAR, remaining + 1)));
    self.cached = true;
}

fn monthAndDay(y: u16, day_of_year: u16) struct { month: u8, day: u8 } {
    var remaining = day_of_year;
    const leap = Time.isLeapYear(y);

    for (DAYS_IN_MONTH, 0..) |days, i| {
        var month_days = days;
        if (i == 1 and leap) month_days = 29;
        if (remaining <= month_days) return .{ .month = @intCast(i + 1), .day = @intCast(remaining) };
        remaining -= month_days;
    }
    return .{ .month = 12, .day = @intCast(remaining) };
}

const testing = std.testing;

test "timestamp parsing" {
    // unix epoch
    var epoch = init(0);
    try testing.expectEqual(@as(u16, Time.EPOCH_YEAR), epoch.year());
    try testing.expectEqual(@as(u8, 1), epoch.month());
    try testing.expectEqual(@as(u8, 1), epoch.dayOfMonth());
    try testing.expectEqual(@as(u8, 0), epoch.hour());
    try testing.expectEqual(@as(u8, 0), epoch.minute());
    try testing.expectEqual(@as(u8, 0), epoch.second());

    // known date 2024-02-29 (leap year)
    var leap = init(1709209845);
    try testing.expectEqual(@as(u16, 2024), leap.year());
    try testing.expectEqual(@as(u8, 2), leap.month());
    try testing.expectEqual(@as(u8, 29), leap.dayOfMonth());
    try testing.expectEqual(@as(u8, 12), leap.hour());
    try testing.expectEqual(@as(u8, 30), leap.minute());
    try testing.expectEqual(@as(u8, 45), leap.second());

    // end of year
    var eoy = init(1704067199);
    try testing.expectEqual(@as(u16, 2023), eoy.year());
    try testing.expectEqual(@as(u8, 12), eoy.month());
    try testing.expectEqual(@as(u8, 31), eoy.dayOfMonth());
    try testing.expectEqual(@as(u8, 23), eoy.hour());
    try testing.expectEqual(@as(u8, 59), eoy.minute());
    try testing.expectEqual(@as(u8, 59), eoy.second());
}

test "leap year handling" {
    // year 2000 (leap year, divisible by 100 and 400)
    var y2000 = init(951868800);
    try testing.expectEqual(@as(u16, 2000), y2000.year());
    try testing.expectEqual(@as(u8, 3), y2000.month());
    try testing.expectEqual(@as(u8, 1), y2000.dayOfMonth());

    // year 2100 (not a leap year)
    var y2100 = init(4107542400);
    try testing.expectEqual(@as(u16, 2100), y2100.year());
    try testing.expectEqual(@as(u8, 3), y2100.month());
    try testing.expectEqual(@as(u8, 1), y2100.dayOfMonth());
}

test "iso8601 format" {
    var buf: [20]u8 = undefined;

    // regular date
    var ts = init(1704067199);
    try testing.expectEqualStrings("2023-12-31T23:59:59Z", ts.iso8601(&buf));

    // epoch
    var epoch = init(0);
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", epoch.iso8601(&buf));
}
