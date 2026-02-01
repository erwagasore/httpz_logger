# httpz_logger

Request logging middleware for [httpz](https://github.com/karlseguin/http.zig) with OpenTelemetry support.

## Features

- 📊 Structured logging in JSON or logfmt format
- 🔗 OpenTelemetry trace context extraction (W3C `traceparent`)
- ⚡ Zero-allocation, thread-local buffer design
- 🎚️ Configurable log levels and status filtering
- 🪶 Lightweight with no external dependencies

## Output

**Logfmt format (default):**
```
timestamp=2025-01-01T12:00:00Z level=info method=GET path=/api/users status=200 size=45 duration_ms=12 client=127.0.0.1:54321 trace_id=0af7651916cd43dd8448eb211c80319c span_id=b7ad6b7169203331 query=page=1 user_agent=curl/8.0 user_id=user123 request_id=req-abc
```

**JSON format:**
```json
{"timestamp":"2025-01-01T12:00:00Z","level":"info","method":"GET","path":"/api/users","query":"page=1","status":200,"size":45,"duration_ms":12,"client":"127.0.0.1:54321","trace_id":"0af7651916cd43dd8448eb211c80319c","span_id":"b7ad6b7169203331","user_agent":"curl/8.0","user_id":"user123","request_id":"req-abc"}
```

## Installation

Add to your `build.zig.zon`:

```zig
.httpz_logger = .{
    .url = "git+https://github.com/erwagasore/httpz_logger#main",
    .hash = "...",
},
```

Add to your `build.zig`:

```zig
const httpz_logger = b.dependency("httpz_logger", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("httpz_logger", httpz_logger.module("httpz_logger"));
```

## Usage

```zig
const std = @import("std");
const httpz = @import("httpz");
const HttpLogger = @import("httpz_logger");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try httpz.Server(void).init(allocator, .{ .port = 8080 }, {});
    defer server.deinit();

    // Add logger middleware
    const logger = try server.middleware(HttpLogger, .{});

    var router = try server.router(.{ .middlewares = &.{logger} });
    router.get("/", handleIndex, .{});

    try server.listen();
}

fn handleIndex(_: *httpz.Request, res: *httpz.Response) !void {
    res.body = "Hello, World!";
}
```

## Configuration

```zig
const logger = try server.middleware(HttpLogger, .{
    .format = .json,              // .logfmt (default) or .json
    .min_status = 400,            // only log responses >= this status (default: 0, log all)
    .min_level = .warn,           // only log at this level or higher (default: .info)
    .log_query = true,            // log query string (default: true)
    .log_user_agent = true,       // log User-Agent header (default: true)
    .log_client = true,           // log client IP address (default: true)
    .log_trace_id = true,         // log OpenTelemetry trace ID (default: true)
    .log_span_id = true,          // log OpenTelemetry span ID (default: true)
    .log_request_id = true,       // log X-Request-ID header (default: true)
    .log_user_id = true,          // log X-User-ID header (default: true)
    .log_errors_to_stderr = true, // log truncation/format errors to stderr (default: true)
});
```

### Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `format` | `Format` | `.logfmt` | Output format: `.logfmt` or `.json` |
| `min_status` | `u16` | `0` | Minimum status code to log (0 = log all) |
| `min_level` | `std.log.Level` | `.info` | Minimum log level to emit |
| `log_query` | `bool` | `true` | Include query string in logs |
| `log_user_agent` | `bool` | `true` | Include User-Agent header in logs |
| `log_client` | `bool` | `true` | Include client IP address in logs |
| `log_trace_id` | `bool` | `true` | Include OpenTelemetry trace ID from `traceparent` header |
| `log_span_id` | `bool` | `true` | Include OpenTelemetry span ID from `traceparent` header |
| `log_request_id` | `bool` | `true` | Include X-Request-ID header in logs |
| `log_user_id` | `bool` | `true` | Include X-User-ID header in logs |
| `log_errors_to_stderr` | `bool` | `true` | Log truncation/format errors to stderr |

## Log Levels

Log level is automatically determined by response status:
- `err` - status >= 500
- `warn` - status >= 400
- `info` - status < 400

Use `min_level` to filter logs. For example, `.min_level = .warn` will only log 4xx and 5xx responses.

## OpenTelemetry Support

The middleware automatically extracts trace context from the W3C `traceparent` header:

```
traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01
```

This enables log correlation with distributed traces in systems like Grafana Loki, Jaeger, and Datadog.

## Performance

### Memory Strategy

httpz_logger uses **thread-local buffers** for zero-allocation, lock-free logging — the same approach used by production loggers like [Zap](https://github.com/uber-go/zap) (Go) and [Zerolog](https://github.com/rs/zerolog) (Go).

| Metric | Value |
|--------|-------|
| Allocation per request | **Zero** |
| Lock contention | **None** |
| Buffer size | 2KB primary + 8KB fallback per thread |
| Memory usage | 10KB × worker threads |

**How it works:**
- Each thread gets its own buffers via Zig's `threadlocal`
- Primary 2KB buffer handles 99% of logs
- 8KB fallback buffer catches oversized entries (long User-Agent, query strings)
- Buffers reused across requests — no malloc/free per log
- No locks needed — threads never share buffers

**Memory footprint examples:**

| Worker Threads | Total Memory |
|----------------|--------------|
| 4 | 40 KB |
| 16 | 160 KB |
| 64 | 640 KB |

This tiered approach follows the [logz](https://github.com/karlseguin/log.zig) pattern used in production Zig applications.

### Why tiered buffers instead of one large buffer?

- Most logs are small (~300-800 bytes) — 2KB is plenty
- Large buffer only used when needed — better cache locality
- Fixed sizes enable compile-time optimization
- Only warns when both buffers are exhausted (truly huge logs)

## License

MIT
