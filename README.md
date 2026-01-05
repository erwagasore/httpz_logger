# httpz_logger

Request logging middleware for [http.zig](https://github.com/karlseguin/http.zig) with OpenTelemetry support.

## Output

**Logfmt format (default):**
```
timestamp=2025-01-01T12:00:00Z level=info method=GET path=/api/users status=200 duration_ms=12 size=45 client=127.0.0.1:54321 trace_id=0af7651916cd43dd8448eb211c80319c span_id=b7ad6b7169203331 user_agent="curl/8.0"
```

**JSON format:**
```json
{"timestamp":"2025-01-01T12:00:00Z","level":"info","trace_id":"0af7651916cd43dd8448eb211c80319c","span_id":"b7ad6b7169203331","method":"GET","client":"127.0.0.1:54321","path":"/api/users","status":200,"size":45,"duration_ms":12,"user_agent":"curl/8.0"}
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
    .format = .json,           // .logfmt (default) or .json
    .min_status = 400,         // only log responses >= this status (default: 0, log all)
    .min_level = .warn,        // only log at this level or higher (default: .info)
    .log_query = true,         // log query string (default: true)
    .log_user_agent = true,    // log User-Agent header (default: true)
    .log_client = true,        // log client IP address (default: true)
    .log_trace_id = true,      // log OpenTelemetry trace ID (default: true)
    .log_span_id = true,       // log OpenTelemetry span ID (default: true)
    .log_request_id = true,    // log X-Request-ID header (default: true)
    .log_user_id = true,       // log X-User-ID header (default: true)
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

## License

MIT
