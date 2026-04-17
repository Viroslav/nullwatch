const std = @import("std");
const std_compat = @import("compat.zig");
const domain = @import("domain.zig");
const Store = @import("store.zig").Store;
const version = @import("version.zig");

const OtlpKeyValue = struct {
    key: []const u8,
    value: std.json.Value,
};

const OtlpTraceSpan = struct {
    traceId: ?[]const u8 = null,
    spanId: ?[]const u8 = null,
    parentSpanId: ?[]const u8 = null,
    name: ?[]const u8 = null,
    kind: ?std.json.Value = null,
    startTimeUnixNano: ?[]const u8 = null,
    endTimeUnixNano: ?[]const u8 = null,
    attributes: ?[]const OtlpKeyValue = null,
    status: ?struct {
        code: ?std.json.Value = null,
        message: ?[]const u8 = null,
    } = null,
};

const OtlpScopeInfo = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
};

const OtlpScopeSpans = struct {
    scope: ?OtlpScopeInfo = null,
    instrumentationLibrary: ?OtlpScopeInfo = null,
    spans: ?[]const OtlpTraceSpan = null,
};

const OtlpResourceSpan = struct {
    resource: ?struct {
        attributes: ?[]const OtlpKeyValue = null,
    } = null,
    scopeSpans: ?[]const OtlpScopeSpans = null,
    instrumentationLibrarySpans: ?[]const OtlpScopeSpans = null,
};

const OtlpTraceExportRequest = struct {
    resourceSpans: ?[]const OtlpResourceSpan = null,
};

const SpanBatchPayload = struct {
    items: []const domain.SpanIngest,
};

const EvalBatchPayload = struct {
    items: []const domain.EvalIngest,
};

pub const Context = struct {
    store: *Store,
    allocator: std.mem.Allocator,
    required_api_token: ?[]const u8 = null,
};

pub const HttpResponse = struct {
    status: []const u8,
    body: []const u8,
    status_code: u16 = 200,
};

pub fn handleRequest(
    ctx: *Context,
    method: []const u8,
    target: []const u8,
    body: []const u8,
    raw_request: []const u8,
) HttpResponse {
    const path = parsePath(target);
    const seg0 = getPathSegment(path.path, 0);
    const seg1 = getPathSegment(path.path, 1);
    const seg2 = getPathSegment(path.path, 2);
    const seg3 = getPathSegment(path.path, 3);

    const is_get = std.mem.eql(u8, method, "GET");
    const is_post = std.mem.eql(u8, method, "POST");

    const request_token = extractBearerToken(raw_request);
    if (!isAuthorized(ctx.required_api_token, seg0, request_token)) {
        return respondError(ctx.allocator, 401, "unauthorized", "Missing or invalid Authorization header");
    }

    if (is_get and eql(seg0, "health") and seg1 == null) {
        return handleHealth(ctx);
    }

    if (is_get and eql(seg0, "v1") and eql(seg1, "capabilities") and seg2 == null) {
        return handleCapabilities(ctx);
    }

    if (is_get and eql(seg0, "v1") and eql(seg1, "summary") and seg2 == null) {
        return handleSummary(ctx);
    }

    if (eql(seg0, "v1") and eql(seg1, "spans")) {
        if (is_get and seg2 == null) return handleSpanList(ctx, path.query);
        if (is_post and seg2 == null) return handleSpanIngest(ctx, body);
        if (is_post and eql(seg2, "bulk") and seg3 == null) return handleSpanBatchIngest(ctx, body);
    }

    if (eql(seg0, "v1") and eql(seg1, "evals")) {
        if (is_get and seg2 == null) return handleEvalList(ctx, path.query);
        if (is_post and seg2 == null) return handleEvalIngest(ctx, body);
        if (is_post and eql(seg2, "bulk") and seg3 == null) return handleEvalBatchIngest(ctx, body);
    }

    if (eql(seg0, "v1") and eql(seg1, "runs")) {
        if (is_get and seg2 == null) return handleRunList(ctx, path.query);
        if (is_get and seg2 != null and seg3 == null) return handleRunDetail(ctx, seg2.?);
    }

    if ((is_post and eql(seg0, "v1") and eql(seg1, "traces") and seg2 == null) or
        (is_post and eql(seg0, "otlp") and eql(seg1, "v1") and eql(seg2, "traces") and seg3 == null))
    {
        return handleOtlpTraces(ctx, body, raw_request);
    }

    return respondError(ctx.allocator, 404, "not_found", "Not found");
}

pub fn extractHeader(raw_request: []const u8, name: []const u8) ?[]const u8 {
    const header_end = std.mem.indexOf(u8, raw_request, "\r\n\r\n") orelse return null;
    var lines = std.mem.splitSequence(u8, raw_request[0..header_end], "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " ");
        if (!std.ascii.eqlIgnoreCase(key, name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

pub fn extractBody(raw_request: []const u8) []const u8 {
    const header_end = std.mem.indexOf(u8, raw_request, "\r\n\r\n") orelse return "";
    return raw_request[header_end + 4 ..];
}

fn handleCapabilities(ctx: *Context) HttpResponse {
    const Capabilities = struct {
        name: []const u8,
        version: []const u8,
        storage: []const u8,
        modes: [2][]const u8,
        entities: [4][]const u8,
        ingest: [3][]const u8,
        role: []const u8,
    };
    return jsonResponse(ctx.allocator, 200, Capabilities{
        .name = "nullwatch",
        .version = version.string,
        .storage = "jsonl",
        .modes = .{ "http", "cli" },
        .entities = .{ "spans", "evals", "runs", "summary" },
        .ingest = .{ "spans", "evals", "otlp-traces" },
        .role = "observability-evals",
    });
}

fn handleHealth(ctx: *Context) HttpResponse {
    const summary = ctx.store.getSystemSummary(ctx.allocator) catch {
        return respondError(ctx.allocator, 500, "internal_error", "Failed to compute health summary");
    };

    const HealthCounts = struct {
        runs: usize,
        spans: usize,
        evals: usize,
        errors: usize,
    };
    const HealthResponse = struct {
        status: []const u8,
        version: []const u8,
        counts: HealthCounts,
    };
    return jsonResponse(ctx.allocator, 200, HealthResponse{
        .status = "ok",
        .version = version.string,
        .counts = .{
            .runs = summary.run_count,
            .spans = summary.span_count,
            .evals = summary.eval_count,
            .errors = summary.error_count,
        },
    });
}

fn handleSummary(ctx: *Context) HttpResponse {
    const summary = ctx.store.getSystemSummary(ctx.allocator) catch {
        return respondError(ctx.allocator, 500, "internal_error", "Failed to compute summary");
    };
    return jsonResponse(ctx.allocator, 200, summary);
}

fn handleSpanIngest(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = std.json.parseFromSlice(domain.SpanIngest, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return respondError(ctx.allocator, 400, "invalid_json", "Failed to parse span payload");
    };
    defer parsed.deinit();

    const record = ctx.store.ingestSpan(parsed.value) catch {
        return respondError(ctx.allocator, 500, "internal_error", "Failed to persist span");
    };
    return jsonResponse(ctx.allocator, 201, record);
}

fn handleSpanBatchIngest(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = std.json.parseFromSlice(SpanBatchPayload, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return respondError(ctx.allocator, 400, "invalid_json", "Failed to parse span batch payload");
    };
    defer parsed.deinit();

    var accepted: usize = 0;
    for (parsed.value.items) |item| {
        _ = ctx.store.ingestSpan(item) catch {
            return respondError(ctx.allocator, 500, "internal_error", "Failed to persist span batch");
        };
        accepted += 1;
    }

    const BatchResponse = struct {
        accepted: usize,
        stored: []const u8,
    };
    return jsonResponse(ctx.allocator, 201, BatchResponse{
        .accepted = accepted,
        .stored = "jsonl",
    });
}

fn handleSpanList(ctx: *Context, query: []const u8) HttpResponse {
    const spans = ctx.store.listSpans(ctx.allocator, parseSpanFilter(query)) catch {
        return respondError(ctx.allocator, 500, "internal_error", "Failed to list spans");
    };
    const SpanListResponse = struct {
        items: []domain.SpanRecord,
    };
    return jsonResponse(ctx.allocator, 200, SpanListResponse{ .items = spans });
}

fn handleEvalIngest(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = std.json.parseFromSlice(domain.EvalIngest, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return respondError(ctx.allocator, 400, "invalid_json", "Failed to parse eval payload");
    };
    defer parsed.deinit();

    const record = ctx.store.ingestEval(parsed.value) catch {
        return respondError(ctx.allocator, 500, "internal_error", "Failed to persist eval");
    };
    return jsonResponse(ctx.allocator, 201, record);
}

fn handleEvalBatchIngest(ctx: *Context, body: []const u8) HttpResponse {
    var parsed = std.json.parseFromSlice(EvalBatchPayload, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return respondError(ctx.allocator, 400, "invalid_json", "Failed to parse eval batch payload");
    };
    defer parsed.deinit();

    var accepted: usize = 0;
    for (parsed.value.items) |item| {
        _ = ctx.store.ingestEval(item) catch {
            return respondError(ctx.allocator, 500, "internal_error", "Failed to persist eval batch");
        };
        accepted += 1;
    }

    const BatchResponse = struct {
        accepted: usize,
        stored: []const u8,
    };
    return jsonResponse(ctx.allocator, 201, BatchResponse{
        .accepted = accepted,
        .stored = "jsonl",
    });
}

fn handleEvalList(ctx: *Context, query: []const u8) HttpResponse {
    const evals = ctx.store.listEvals(ctx.allocator, parseEvalFilter(query)) catch {
        return respondError(ctx.allocator, 500, "internal_error", "Failed to list evals");
    };
    const EvalListResponse = struct {
        items: []domain.EvalRecord,
    };
    return jsonResponse(ctx.allocator, 200, EvalListResponse{ .items = evals });
}

fn handleRunList(ctx: *Context, query: []const u8) HttpResponse {
    const runs = ctx.store.listRuns(ctx.allocator, parseRunFilter(query)) catch {
        return respondError(ctx.allocator, 500, "internal_error", "Failed to list runs");
    };
    const RunListResponse = struct {
        items: []domain.RunSummary,
    };
    return jsonResponse(ctx.allocator, 200, RunListResponse{ .items = runs });
}

fn handleRunDetail(ctx: *Context, run_id: []const u8) HttpResponse {
    const detail = ctx.store.getRunDetail(ctx.allocator, run_id) catch {
        return respondError(ctx.allocator, 500, "internal_error", "Failed to load run detail");
    };
    if (detail == null) {
        return respondError(ctx.allocator, 404, "not_found", "Run not found");
    }
    return jsonResponse(ctx.allocator, 200, detail.?);
}

fn handleOtlpTraces(ctx: *Context, body: []const u8, raw_request: []const u8) HttpResponse {
    const content_type = normalizeContentType(extractHeader(raw_request, "Content-Type") orelse "application/json");
    if (!isJsonContentType(content_type)) {
        return respondError(ctx.allocator, 415, "unsupported_media_type", "nullwatch currently supports OTLP JSON only");
    }

    var parsed = std.json.parseFromSlice(OtlpTraceExportRequest, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return respondError(ctx.allocator, 400, "invalid_json", "Invalid OTLP JSON payload");
    };
    defer parsed.deinit();

    var accepted: usize = 0;
    const resource_spans = parsed.value.resourceSpans orelse @as([]const OtlpResourceSpan, &.{});
    for (resource_spans) |resource_span| {
        const resource_attributes: []const OtlpKeyValue = if (resource_span.resource) |resource| (resource.attributes orelse &.{}) else &.{};
        if (resource_span.scopeSpans) |scope_spans| {
            ingestOtlpScopeSpans(ctx, resource_attributes, scope_spans, &accepted) catch {
                return respondError(ctx.allocator, 500, "internal_error", "Failed to persist OTLP spans");
            };
        }
        if (resource_span.instrumentationLibrarySpans) |scope_spans| {
            ingestOtlpScopeSpans(ctx, resource_attributes, scope_spans, &accepted) catch {
                return respondError(ctx.allocator, 500, "internal_error", "Failed to persist OTLP spans");
            };
        }
    }

    const OtlpResponse = struct {
        accepted_spans: usize,
        stored: []const u8,
    };
    return jsonResponse(ctx.allocator, 200, OtlpResponse{
        .accepted_spans = accepted,
        .stored = "jsonl",
    });
}

fn ingestOtlpScopeSpans(
    ctx: *Context,
    resource_attributes: []const OtlpKeyValue,
    scope_spans: []const OtlpScopeSpans,
    accepted: *usize,
) !void {
    for (scope_spans) |scope_span| {
        const scope_name = if (scope_span.scope) |scope| scope.name else if (scope_span.instrumentationLibrary) |lib| lib.name else null;
        const spans = scope_span.spans orelse @as([]const OtlpTraceSpan, &.{});

        for (spans) |span| {
            const trace_id = span.traceId orelse continue;
            const span_id = span.spanId orelse continue;
            const attrs = span.attributes orelse @as([]const OtlpKeyValue, &.{});
            const run_id = (try firstOtlpAttributeText(ctx.allocator, attrs, &.{ "nullwatch.run_id", "nulltickets.run_id", "run_id" })) orelse
                (try firstOtlpAttributeText(ctx.allocator, resource_attributes, &.{ "nullwatch.run_id", "nulltickets.run_id", "run_id" })) orelse
                trace_id;
            const source = (try firstOtlpAttributeText(ctx.allocator, resource_attributes, &.{"service.name"})) orelse
                scope_name orelse
                "otlp";
            const operation = span.name orelse "unnamed";
            const started_at_ms = parseUnixNanoMs(span.startTimeUnixNano) orelse std_compat.time.milliTimestamp();
            const ended_at_ms = parseUnixNanoMs(span.endTimeUnixNano);
            const attributes_json = try otlpAttributesJson(ctx.allocator, attrs);
            const success_text = try firstOtlpAttributeText(ctx.allocator, attrs, &.{"success"});
            const status = determineOtlpStatus(span, success_text);
            const error_message = if (span.status) |status_payload|
                status_payload.message orelse (try firstOtlpAttributeText(ctx.allocator, attrs, &.{ "error_message", "message", "detail" }))
            else
                try firstOtlpAttributeText(ctx.allocator, attrs, &.{ "error_message", "message", "detail" });

            _ = try ctx.store.ingestSpan(.{
                .run_id = run_id,
                .trace_id = trace_id,
                .span_id = span_id,
                .parent_span_id = span.parentSpanId,
                .source = source,
                .operation = operation,
                .status = status,
                .started_at_ms = started_at_ms,
                .ended_at_ms = ended_at_ms,
                .duration_ms = null,
                .session_id = (try firstOtlpAttributeText(ctx.allocator, attrs, &.{ "session_id", "nullclaw.session_id", "openclaw.sessionId" })) orelse
                    (try firstOtlpAttributeText(ctx.allocator, resource_attributes, &.{ "session_id", "nullclaw.session_id", "openclaw.sessionId" })),
                .task_id = (try firstOtlpAttributeText(ctx.allocator, attrs, &.{ "task_id", "nulltickets.task_id" })) orelse
                    (try firstOtlpAttributeText(ctx.allocator, resource_attributes, &.{ "task_id", "nulltickets.task_id" })),
                .agent_id = (try firstOtlpAttributeText(ctx.allocator, attrs, &.{ "agent_id", "nullclaw.agent_id" })) orelse
                    (try firstOtlpAttributeText(ctx.allocator, resource_attributes, &.{ "agent_id", "nullclaw.agent_id" })),
                .model = try firstOtlpAttributeText(ctx.allocator, attrs, &.{ "model", "nullclaw.model", "openclaw.model" }),
                .prompt_version = try firstOtlpAttributeText(ctx.allocator, attrs, &.{ "prompt_version", "nullclaw.prompt_version", "openclaw.promptVersion" }),
                .tool_name = try firstOtlpAttributeText(ctx.allocator, attrs, &.{ "tool", "tool_name", "nullclaw.tool_name" }),
                .input_tokens = try parseOptionalU64Attr(ctx.allocator, attrs, &.{ "input_tokens", "prompt_tokens", "openclaw.promptTokens" }),
                .output_tokens = try parseOptionalU64Attr(ctx.allocator, attrs, &.{ "output_tokens", "completion_tokens", "openclaw.completionTokens" }),
                .cost_usd = try parseOptionalF64Attr(ctx.allocator, attrs, &.{ "cost_usd", "cost", "openclaw.costUsd" }),
                .error_message = error_message,
                .attributes_json = attributes_json,
            });
            accepted.* += 1;
        }
    }
}

fn determineOtlpStatus(span: OtlpTraceSpan, success_text: ?[]const u8) []const u8 {
    if (success_text) |success| {
        if (std.ascii.eqlIgnoreCase(success, "false")) return "error";
        if (std.ascii.eqlIgnoreCase(success, "true")) return "ok";
    }

    if (span.status) |status_payload| {
        if (status_payload.code) |code| {
            return switch (code) {
                .integer => |v| if (v == 2) "error" else if (v == 1) "ok" else "unset",
                .string => |v| if (std.mem.eql(u8, v, "2") or std.ascii.eqlIgnoreCase(v, "error")) "error" else if (std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "ok")) "ok" else "unset",
                .number_string => |v| if (std.mem.eql(u8, v, "2")) "error" else if (std.mem.eql(u8, v, "1")) "ok" else "unset",
                else => "unset",
            };
        }
    }

    if (span.name) |name| {
        if (std.ascii.eqlIgnoreCase(name, "error")) return "error";
    }
    return "ok";
}

fn parseSpanFilter(query: []const u8) domain.SpanFilter {
    return .{
        .run_id = queryValue(query, "run_id"),
        .trace_id = queryValue(query, "trace_id"),
        .source = queryValue(query, "source"),
        .operation = queryValue(query, "operation"),
        .status = queryValue(query, "status"),
        .model = queryValue(query, "model"),
        .tool_name = queryValue(query, "tool_name"),
        .task_id = queryValue(query, "task_id"),
        .session_id = queryValue(query, "session_id"),
        .agent_id = queryValue(query, "agent_id"),
        .limit = parseUsizeQuery(query, "limit"),
    };
}

fn parseEvalFilter(query: []const u8) domain.EvalFilter {
    return .{
        .run_id = queryValue(query, "run_id"),
        .verdict = queryValue(query, "verdict"),
        .eval_key = queryValue(query, "eval_key"),
        .scorer = queryValue(query, "scorer"),
        .dataset = queryValue(query, "dataset"),
        .limit = parseUsizeQuery(query, "limit"),
    };
}

fn parseRunFilter(query: []const u8) domain.RunFilter {
    return .{
        .run_id = queryValue(query, "run_id"),
        .source = queryValue(query, "source"),
        .operation = queryValue(query, "operation"),
        .status = queryValue(query, "status"),
        .model = queryValue(query, "model"),
        .tool_name = queryValue(query, "tool_name"),
        .verdict = queryValue(query, "verdict"),
        .dataset = queryValue(query, "dataset"),
        .limit = parseUsizeQuery(query, "limit"),
    };
}

fn queryValue(query: []const u8, key: []const u8) ?[]const u8 {
    if (query.len == 0) return null;
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const candidate = kv.next() orelse continue;
        const value = kv.next() orelse continue;
        if (std.mem.eql(u8, candidate, key)) return value;
    }
    return null;
}

fn parseUsizeQuery(query: []const u8, key: []const u8) ?usize {
    const value = queryValue(query, key) orelse return null;
    return std.fmt.parseInt(usize, value, 10) catch null;
}

fn firstOtlpAttributeText(allocator: std.mem.Allocator, attributes: []const OtlpKeyValue, keys: []const []const u8) !?[]const u8 {
    for (keys) |key| {
        if (try getOtlpAttributeText(allocator, attributes, key)) |value| return value;
    }
    return null;
}

fn getOtlpAttributeText(allocator: std.mem.Allocator, attributes: []const OtlpKeyValue, key: []const u8) !?[]const u8 {
    for (attributes) |attr| {
        if (std.mem.eql(u8, attr.key, key)) {
            return try otlpAnyValueToText(allocator, attr.value);
        }
    }
    return null;
}

fn parseOptionalU64Attr(allocator: std.mem.Allocator, attributes: []const OtlpKeyValue, keys: []const []const u8) !?u64 {
    const text = try firstOtlpAttributeText(allocator, attributes, keys) orelse return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

fn parseOptionalF64Attr(allocator: std.mem.Allocator, attributes: []const OtlpKeyValue, keys: []const []const u8) !?f64 {
    const text = try firstOtlpAttributeText(allocator, attributes, keys) orelse return null;
    return std.fmt.parseFloat(f64, text) catch null;
}

fn otlpAttributesJson(allocator: std.mem.Allocator, attributes: []const OtlpKeyValue) ![]const u8 {
    return try std.json.Stringify.valueAlloc(allocator, attributes, .{});
}

fn otlpAnyValueToText(allocator: std.mem.Allocator, value: std.json.Value) !?[]const u8 {
    switch (value) {
        .object => |obj| {
            if (obj.get("stringValue")) |v| return try jsonValueToText(allocator, v);
            if (obj.get("intValue")) |v| return try jsonValueToText(allocator, v);
            if (obj.get("doubleValue")) |v| return try jsonValueToText(allocator, v);
            if (obj.get("boolValue")) |v| return try jsonValueToText(allocator, v);
            if (obj.get("bytesValue")) |v| return try jsonValueToText(allocator, v);
            return try std.json.Stringify.valueAlloc(allocator, value, .{});
        },
        else => return try jsonValueToText(allocator, value),
    }
}

fn jsonValueToText(allocator: std.mem.Allocator, value: std.json.Value) !?[]const u8 {
    return switch (value) {
        .null => null,
        .string => |v| v,
        .number_string => |v| v,
        .integer => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .float => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .bool => |v| if (v) "true" else "false",
        else => try std.json.Stringify.valueAlloc(allocator, value, .{}),
    };
}

fn parseUnixNanoMs(value: ?[]const u8) ?i64 {
    const raw = value orelse return null;
    const nanos = std.fmt.parseInt(i64, raw, 10) catch return null;
    return @divTrunc(nanos, 1_000_000);
}

fn normalizeContentType(value: []const u8) []const u8 {
    const ct = if (std.mem.indexOfScalar(u8, value, ';')) |idx| value[0..idx] else value;
    return std.mem.trim(u8, ct, " \t");
}

fn isJsonContentType(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "application/json");
}

fn extractBearerToken(raw_request: []const u8) ?[]const u8 {
    const header = extractHeader(raw_request, "Authorization") orelse return null;
    if (!std.ascii.startsWithIgnoreCase(header, "Bearer ")) return null;
    return header["Bearer ".len..];
}

fn isAuthorized(required_token: ?[]const u8, first_segment: ?[]const u8, request_token: ?[]const u8) bool {
    if (eql(first_segment, "health")) return true;
    if (required_token == null) return true;
    if (request_token == null) return false;
    return std.mem.eql(u8, required_token.?, request_token.?);
}

fn parsePath(target: []const u8) struct { path: []const u8, query: []const u8 } {
    const qm = std.mem.indexOfScalar(u8, target, '?') orelse return .{ .path = trimLeadingSlash(target), .query = "" };
    return .{
        .path = trimLeadingSlash(target[0..qm]),
        .query = target[qm + 1 ..],
    };
}

fn trimLeadingSlash(value: []const u8) []const u8 {
    if (value.len > 0 and value[0] == '/') return value[1..];
    return value;
}

fn getPathSegment(path: []const u8, index: usize) ?[]const u8 {
    var it = std.mem.splitScalar(u8, path, '/');
    var current: usize = 0;
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (current == index) return part;
        current += 1;
    }
    return null;
}

fn respondError(allocator: std.mem.Allocator, status_code: u16, code: []const u8, message: []const u8) HttpResponse {
    const ErrorResponse = struct {
        @"error": []const u8,
        message: []const u8,
    };
    return jsonResponse(allocator, status_code, ErrorResponse{
        .@"error" = code,
        .message = message,
    });
}

fn jsonResponse(allocator: std.mem.Allocator, status_code: u16, value: anytype) HttpResponse {
    const body = encodeJson(allocator, value) catch {
        return .{
            .status = "500 Internal Server Error",
            .body = "{\"error\":\"internal_error\",\"message\":\"Failed to encode JSON\"}",
            .status_code = 500,
        };
    };
    return .{
        .status = statusTextFromCode(status_code),
        .body = body,
        .status_code = status_code,
    };
}

fn encodeJson(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn statusTextFromCode(status_code: u16) []const u8 {
    return switch (status_code) {
        200 => "200 OK",
        201 => "201 Created",
        400 => "400 Bad Request",
        401 => "401 Unauthorized",
        404 => "404 Not Found",
        415 => "415 Unsupported Media Type",
        else => "500 Internal Server Error",
    };
}

fn eql(value: ?[]const u8, expected: []const u8) bool {
    return value != null and std.mem.eql(u8, value.?, expected);
}
