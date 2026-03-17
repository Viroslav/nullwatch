const std = @import("std");
const api = @import("api.zig");
const config = @import("config.zig");
const domain = @import("domain.zig");
const Store = @import("store.zig").Store;
const version = @import("version.zig");

const max_request_size: usize = 256 * 1024;

const RuntimeConfig = struct {
    host: []const u8,
    port: u16,
    data_dir: []const u8,
    api_token: ?[]const u8,

    fn deinit(self: *RuntimeConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.data_dir);
        if (self.api_token) |token| allocator.free(token);
    }
};

const RuntimeOverrides = struct {
    host: ?[]const u8 = null,
    port: ?u16 = null,
    data_dir: ?[]const u8 = null,
    token: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    if (args.next()) |first_arg| {
        if (std.mem.eql(u8, first_arg, "--export-manifest")) {
            try @import("export_manifest.zig").run();
            return;
        }
        if (std.mem.eql(u8, first_arg, "--from-json")) {
            if (args.next()) |json_str| {
                try @import("from_json.zig").run(allocator, json_str);
            } else {
                std.debug.print("error: --from-json requires a JSON argument\n", .{});
                std.process.exit(1);
            }
            return;
        }
    }

    var args2 = try std.process.argsWithAllocator(allocator);
    defer args2.deinit();
    _ = args2.next();

    const command = args2.next() orelse "serve";

    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "version")) {
        std.debug.print("nullwatch v{s}\n", .{version.string});
        return;
    }

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, command, "serve")) {
        var parsed = try parseServeArgs(allocator, &args2);
        defer parsed.runtime.deinit(allocator);
        try runServer(allocator, parsed.runtime);
        return;
    }

    if (std.mem.eql(u8, command, "summary")) {
        var parsed = try parseCommonArgs(allocator, &args2);
        defer parsed.deinit(allocator);
        try runSummaryCommand(allocator, parsed.runtime);
        return;
    }

    if (std.mem.eql(u8, command, "runs")) {
        var parsed = try parseRunsArgs(allocator, &args2);
        defer parsed.common.runtime.deinit(allocator);
        try runRunsCommand(allocator, parsed.common.runtime, parsed.filter);
        return;
    }

    if (std.mem.eql(u8, command, "run")) {
        var parsed = try parseRunDetailArgs(allocator, &args2);
        defer parsed.common.runtime.deinit(allocator);
        try runDetailCommand(allocator, parsed.common.runtime, parsed.run_id);
        return;
    }

    if (std.mem.eql(u8, command, "spans")) {
        var parsed = try parseSpansArgs(allocator, &args2);
        defer parsed.common.runtime.deinit(allocator);
        try runSpansCommand(allocator, parsed.common.runtime, parsed.filter);
        return;
    }

    if (std.mem.eql(u8, command, "evals")) {
        var parsed = try parseEvalsArgs(allocator, &args2);
        defer parsed.common.runtime.deinit(allocator);
        try runEvalsCommand(allocator, parsed.common.runtime, parsed.filter);
        return;
    }

    if (std.mem.eql(u8, command, "ingest-span")) {
        var parsed = try parseJsonIngestArgs(allocator, &args2);
        defer parsed.common.runtime.deinit(allocator);
        try runSpanIngestCommand(allocator, parsed.common.runtime, parsed.json_payload);
        return;
    }

    if (std.mem.eql(u8, command, "ingest-eval")) {
        var parsed = try parseJsonIngestArgs(allocator, &args2);
        defer parsed.common.runtime.deinit(allocator);
        try runEvalIngestCommand(allocator, parsed.common.runtime, parsed.json_payload);
        return;
    }

    std.debug.print("unknown command: {s}\n\n", .{command});
    printUsage();
    std.process.exit(1);
}

fn runServer(allocator: std.mem.Allocator, runtime: RuntimeConfig) !void {
    var store = try Store.init(allocator, runtime.data_dir);
    defer store.deinit();

    const addr = try std.net.Address.resolveIp(runtime.host, runtime.port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("nullwatch v{s}\n", .{version.string});
    std.debug.print("data dir: {s}\n", .{runtime.data_dir});
    std.debug.print("listening on http://{s}:{d}\n", .{ runtime.host, runtime.port });

    while (true) {
        const conn = server.accept() catch |err| {
            std.debug.print("accept error: {}\n", .{err});
            continue;
        };
        defer conn.stream.close();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const req_alloc = arena.allocator();

        var req_buf: [max_request_size]u8 = undefined;
        const n = conn.stream.read(&req_buf) catch continue;
        if (n == 0) continue;
        const raw = req_buf[0..n];

        const first_line_end = std.mem.indexOf(u8, raw, "\r\n") orelse continue;
        const first_line = raw[0..first_line_end];
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse continue;
        const target = parts.next() orelse continue;

        var full_request = raw;
        if (api.extractHeader(raw, "Content-Length")) |cl_str| {
            const content_length = std.fmt.parseInt(usize, cl_str, 10) catch 0;
            if (content_length > 0) {
                const header_end_pos = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse continue;
                const body_start = header_end_pos + 4;
                const body_received = n - body_start;
                if (body_received < content_length) {
                    const total_size = body_start + content_length;
                    if (total_size > max_request_size) continue;
                    const full_buf = req_alloc.alloc(u8, total_size) catch continue;
                    @memcpy(full_buf[0..n], raw);
                    var total_read = n;
                    while (total_read < total_size) {
                        const extra = conn.stream.read(full_buf[total_read..total_size]) catch break;
                        if (extra == 0) break;
                        total_read += extra;
                    }
                    full_request = full_buf[0..total_read];
                }
            }
        }

        const body = api.extractBody(full_request);
        var ctx = api.Context{
            .store = &store,
            .allocator = req_alloc,
            .required_api_token = runtime.api_token,
        };
        const response = api.handleRequest(&ctx, method, target, body, full_request);

        var resp_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(
            &resp_buf,
            "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ response.status, response.body.len },
        ) catch continue;
        _ = conn.stream.write(header) catch continue;
        _ = conn.stream.write(response.body) catch continue;
    }
}

fn runSummaryCommand(allocator: std.mem.Allocator, runtime: RuntimeConfig) !void {
    var store = try Store.init(allocator, runtime.data_dir);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const summary = try store.getSystemSummary(arena.allocator());
    try writeJsonToStdout(allocator, summary);
}

fn runRunsCommand(allocator: std.mem.Allocator, runtime: RuntimeConfig, filter: domain.RunFilter) !void {
    var store = try Store.init(allocator, runtime.data_dir);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const runs = try store.listRuns(arena.allocator(), filter);
    const RunListResponse = struct {
        items: []domain.RunSummary,
    };
    try writeJsonToStdout(allocator, RunListResponse{ .items = runs });
}

fn runDetailCommand(allocator: std.mem.Allocator, runtime: RuntimeConfig, run_id: []const u8) !void {
    var store = try Store.init(allocator, runtime.data_dir);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const detail = try store.getRunDetail(arena.allocator(), run_id);
    if (detail == null) {
        std.debug.print("run not found: {s}\n", .{run_id});
        std.process.exit(1);
    }
    try writeJsonToStdout(allocator, detail.?);
}

fn runSpansCommand(allocator: std.mem.Allocator, runtime: RuntimeConfig, filter: domain.SpanFilter) !void {
    var store = try Store.init(allocator, runtime.data_dir);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const spans = try store.listSpans(arena.allocator(), filter);
    const SpanListResponse = struct {
        items: []domain.SpanRecord,
    };
    try writeJsonToStdout(allocator, SpanListResponse{ .items = spans });
}

fn runEvalsCommand(allocator: std.mem.Allocator, runtime: RuntimeConfig, filter: domain.EvalFilter) !void {
    var store = try Store.init(allocator, runtime.data_dir);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const evals = try store.listEvals(arena.allocator(), filter);
    const EvalListResponse = struct {
        items: []domain.EvalRecord,
    };
    try writeJsonToStdout(allocator, EvalListResponse{ .items = evals });
}

fn runSpanIngestCommand(allocator: std.mem.Allocator, runtime: RuntimeConfig, json_payload: []const u8) !void {
    var store = try Store.init(allocator, runtime.data_dir);
    defer store.deinit();

    const parsed = try std.json.parseFromSlice(domain.SpanIngest, allocator, json_payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const record = try store.ingestSpan(parsed.value);
    try writeJsonToStdout(allocator, record);
}

fn runEvalIngestCommand(allocator: std.mem.Allocator, runtime: RuntimeConfig, json_payload: []const u8) !void {
    var store = try Store.init(allocator, runtime.data_dir);
    defer store.deinit();

    const parsed = try std.json.parseFromSlice(domain.EvalIngest, allocator, json_payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const record = try store.ingestEval(parsed.value);
    try writeJsonToStdout(allocator, record);
}

fn parseServeArgs(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !struct { runtime: RuntimeConfig } {
    var overrides = RuntimeOverrides{};

    while (args.next()) |arg| {
        if (try maybeParseRuntimeFlag(args, &overrides, arg, true)) continue;
        return error.InvalidArgument;
    }

    return .{ .runtime = try resolveRuntimeConfig(allocator, overrides) };
}

fn parseCommonArgs(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !struct {
    runtime: RuntimeConfig,

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.runtime.deinit(alloc);
    }
} {
    var overrides = RuntimeOverrides{};
    while (args.next()) |arg| {
        if (try maybeParseRuntimeFlag(args, &overrides, arg, false)) continue;
        return error.InvalidArgument;
    }

    return .{ .runtime = try resolveRuntimeConfig(allocator, overrides) };
}

fn parseRunsArgs(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !struct {
    common: struct { runtime: RuntimeConfig },
    filter: domain.RunFilter,
} {
    var overrides = RuntimeOverrides{};
    var filter = domain.RunFilter{};

    while (args.next()) |arg| {
        if (try maybeParseRuntimeFlag(args, &overrides, arg, false)) continue;
        if (std.mem.eql(u8, arg, "--run-id")) {
            filter.run_id = try requireNext(args, "--run-id");
        } else if (std.mem.eql(u8, arg, "--source")) {
            filter.source = try requireNext(args, "--source");
        } else if (std.mem.eql(u8, arg, "--operation")) {
            filter.operation = try requireNext(args, "--operation");
        } else if (std.mem.eql(u8, arg, "--status")) {
            filter.status = try requireNext(args, "--status");
        } else if (std.mem.eql(u8, arg, "--model")) {
            filter.model = try requireNext(args, "--model");
        } else if (std.mem.eql(u8, arg, "--tool-name")) {
            filter.tool_name = try requireNext(args, "--tool-name");
        } else if (std.mem.eql(u8, arg, "--verdict")) {
            filter.verdict = try requireNext(args, "--verdict");
        } else if (std.mem.eql(u8, arg, "--dataset")) {
            filter.dataset = try requireNext(args, "--dataset");
        } else if (std.mem.eql(u8, arg, "--limit")) {
            filter.limit = try parseRequiredUsize(args, "--limit");
        } else {
            return error.InvalidArgument;
        }
    }

    return .{
        .common = .{ .runtime = try resolveRuntimeConfig(allocator, overrides) },
        .filter = filter,
    };
}

fn parseRunDetailArgs(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !struct {
    common: struct { runtime: RuntimeConfig },
    run_id: []const u8,
} {
    const run_id = args.next() orelse return error.MissingArgument;
    var overrides = RuntimeOverrides{};

    while (args.next()) |arg| {
        if (try maybeParseRuntimeFlag(args, &overrides, arg, false)) continue;
        return error.InvalidArgument;
    }

    return .{
        .common = .{ .runtime = try resolveRuntimeConfig(allocator, overrides) },
        .run_id = run_id,
    };
}

fn parseSpansArgs(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !struct {
    common: struct { runtime: RuntimeConfig },
    filter: domain.SpanFilter,
} {
    var overrides = RuntimeOverrides{};
    var filter = domain.SpanFilter{};

    while (args.next()) |arg| {
        if (try maybeParseRuntimeFlag(args, &overrides, arg, false)) continue;
        if (std.mem.eql(u8, arg, "--run-id")) {
            filter.run_id = try requireNext(args, "--run-id");
        } else if (std.mem.eql(u8, arg, "--trace-id")) {
            filter.trace_id = try requireNext(args, "--trace-id");
        } else if (std.mem.eql(u8, arg, "--source")) {
            filter.source = try requireNext(args, "--source");
        } else if (std.mem.eql(u8, arg, "--operation")) {
            filter.operation = try requireNext(args, "--operation");
        } else if (std.mem.eql(u8, arg, "--status")) {
            filter.status = try requireNext(args, "--status");
        } else if (std.mem.eql(u8, arg, "--model")) {
            filter.model = try requireNext(args, "--model");
        } else if (std.mem.eql(u8, arg, "--tool-name")) {
            filter.tool_name = try requireNext(args, "--tool-name");
        } else if (std.mem.eql(u8, arg, "--task-id")) {
            filter.task_id = try requireNext(args, "--task-id");
        } else if (std.mem.eql(u8, arg, "--session-id")) {
            filter.session_id = try requireNext(args, "--session-id");
        } else if (std.mem.eql(u8, arg, "--agent-id")) {
            filter.agent_id = try requireNext(args, "--agent-id");
        } else if (std.mem.eql(u8, arg, "--limit")) {
            filter.limit = try parseRequiredUsize(args, "--limit");
        } else {
            return error.InvalidArgument;
        }
    }

    return .{
        .common = .{ .runtime = try resolveRuntimeConfig(allocator, overrides) },
        .filter = filter,
    };
}

fn parseEvalsArgs(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !struct {
    common: struct { runtime: RuntimeConfig },
    filter: domain.EvalFilter,
} {
    var overrides = RuntimeOverrides{};
    var filter = domain.EvalFilter{};

    while (args.next()) |arg| {
        if (try maybeParseRuntimeFlag(args, &overrides, arg, false)) continue;
        if (std.mem.eql(u8, arg, "--run-id")) {
            filter.run_id = try requireNext(args, "--run-id");
        } else if (std.mem.eql(u8, arg, "--verdict")) {
            filter.verdict = try requireNext(args, "--verdict");
        } else if (std.mem.eql(u8, arg, "--eval-key")) {
            filter.eval_key = try requireNext(args, "--eval-key");
        } else if (std.mem.eql(u8, arg, "--scorer")) {
            filter.scorer = try requireNext(args, "--scorer");
        } else if (std.mem.eql(u8, arg, "--dataset")) {
            filter.dataset = try requireNext(args, "--dataset");
        } else if (std.mem.eql(u8, arg, "--limit")) {
            filter.limit = try parseRequiredUsize(args, "--limit");
        } else {
            return error.InvalidArgument;
        }
    }

    return .{
        .common = .{ .runtime = try resolveRuntimeConfig(allocator, overrides) },
        .filter = filter,
    };
}

fn parseJsonIngestArgs(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !struct {
    common: struct { runtime: RuntimeConfig },
    json_payload: []const u8,
} {
    var overrides = RuntimeOverrides{};
    var json_payload: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (try maybeParseRuntimeFlag(args, &overrides, arg, false)) continue;
        if (std.mem.eql(u8, arg, "--json")) {
            json_payload = try requireNext(args, "--json");
        } else {
            return error.InvalidArgument;
        }
    }

    return .{
        .common = .{ .runtime = try resolveRuntimeConfig(allocator, overrides) },
        .json_payload = json_payload orelse return error.MissingArgument,
    };
}

fn maybeParseRuntimeFlag(
    args: *std.process.ArgIterator,
    overrides: *RuntimeOverrides,
    arg: []const u8,
    allow_port_and_host: bool,
) !bool {
    if (allow_port_and_host and std.mem.eql(u8, arg, "--host")) {
        overrides.host = try requireNext(args, "--host");
        return true;
    }
    if (allow_port_and_host and std.mem.eql(u8, arg, "--port")) {
        overrides.port = try parseRequiredU16(args, "--port");
        return true;
    }
    if (std.mem.eql(u8, arg, "--data-dir")) {
        overrides.data_dir = try requireNext(args, "--data-dir");
        return true;
    }
    if (std.mem.eql(u8, arg, "--token")) {
        overrides.token = try requireNext(args, "--token");
        return true;
    }
    if (std.mem.eql(u8, arg, "--config")) {
        overrides.config_path = try requireNext(args, "--config");
        return true;
    }
    return false;
}

fn resolveRuntimeConfig(allocator: std.mem.Allocator, overrides: RuntimeOverrides) !RuntimeConfig {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const cfg_path = try config.resolveConfigPath(arena.allocator(), overrides.config_path);
    var cfg = try config.loadFromFile(arena.allocator(), cfg_path);
    try config.resolveRelativePaths(arena.allocator(), cfg_path, &cfg);

    const host = try allocator.dupe(u8, overrides.host orelse cfg.host);
    const data_dir = try allocator.dupe(u8, overrides.data_dir orelse cfg.data_dir);
    const api_token = if (overrides.token orelse cfg.api_token) |token|
        try allocator.dupe(u8, token)
    else
        null;

    return .{
        .host = host,
        .port = overrides.port orelse cfg.port,
        .data_dir = data_dir,
        .api_token = api_token,
    };
}

fn parseRequiredU16(args: *std.process.ArgIterator, flag: []const u8) !u16 {
    const value = try requireNext(args, flag);
    return std.fmt.parseInt(u16, value, 10);
}

fn parseRequiredUsize(args: *std.process.ArgIterator, flag: []const u8) !usize {
    const value = try requireNext(args, flag);
    return std.fmt.parseInt(usize, value, 10);
}

fn requireNext(args: *std.process.ArgIterator, flag: []const u8) ![]const u8 {
    return args.next() orelse {
        std.debug.print("missing value for {s}\n", .{flag});
        return error.MissingArgument;
    };
}

fn writeJsonToStdout(allocator: std.mem.Allocator, value: anytype) !void {
    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    const body = try out.toOwnedSlice();
    defer allocator.free(body);

    try std.fs.File.stdout().writeAll(body);
    try std.fs.File.stdout().writeAll("\n");
}

fn printUsage() void {
    std.debug.print(
        \\nullwatch v{s}
        \\
        \\Usage:
        \\  nullwatch serve [--host IP] [--port N] [--data-dir PATH] [--config PATH] [--token TOKEN]
        \\  nullwatch summary [--data-dir PATH] [--config PATH]
        \\  nullwatch runs [--run-id ID] [--source SRC] [--operation OP] [--status STATUS] [--model MODEL] [--tool-name NAME] [--verdict VERDICT] [--dataset NAME] [--limit N]
        \\  nullwatch run <run-id> [--data-dir PATH] [--config PATH]
        \\  nullwatch spans [--run-id ID] [--trace-id ID] [--source SRC] [--operation OP] [--status STATUS] [--model MODEL] [--tool-name NAME] [--task-id ID] [--session-id ID] [--agent-id ID] [--limit N]
        \\  nullwatch evals [--run-id ID] [--verdict VERDICT] [--eval-key KEY] [--scorer NAME] [--dataset NAME] [--limit N]
        \\  nullwatch ingest-span --json '<payload>' [--data-dir PATH] [--config PATH]
        \\  nullwatch ingest-eval --json '<payload>' [--data-dir PATH] [--config PATH]
        \\  nullwatch --export-manifest
        \\  nullwatch --from-json '<wizard answers json>'
        \\  nullwatch version
        \\
        \\HTTP API:
        \\  GET  /health
        \\  GET  /v1/capabilities
        \\  GET  /v1/summary
        \\  GET  /v1/spans
        \\  POST /v1/spans
        \\  POST /v1/spans/bulk
        \\  GET  /v1/evals
        \\  POST /v1/evals
        \\  POST /v1/evals/bulk
        \\  GET  /v1/runs
        \\  GET  /v1/runs/<run-id>
        \\  POST /v1/traces
        \\  POST /otlp/v1/traces
        \\
        , .{version.string},
    );
}

test {
    _ = api;
    _ = config;
    _ = domain;
    _ = Store;
    _ = @import("export_manifest.zig");
    _ = @import("from_json.zig");
}
