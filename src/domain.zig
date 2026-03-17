const std = @import("std");

pub const SpanIngest = struct {
    run_id: []const u8,
    trace_id: []const u8,
    span_id: []const u8,
    parent_span_id: ?[]const u8 = null,
    source: []const u8,
    operation: []const u8,
    status: []const u8 = "ok",
    started_at_ms: i64,
    ended_at_ms: ?i64 = null,
    duration_ms: ?f64 = null,
    session_id: ?[]const u8 = null,
    task_id: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    model: ?[]const u8 = null,
    prompt_version: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cost_usd: ?f64 = null,
    error_message: ?[]const u8 = null,
    attributes_json: ?[]const u8 = null,
};

pub const SpanRecord = struct {
    id: []const u8,
    stored_at_ms: i64,
    run_id: []const u8,
    trace_id: []const u8,
    span_id: []const u8,
    parent_span_id: ?[]const u8 = null,
    source: []const u8,
    operation: []const u8,
    status: []const u8,
    started_at_ms: i64,
    ended_at_ms: ?i64 = null,
    duration_ms: f64,
    session_id: ?[]const u8 = null,
    task_id: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    model: ?[]const u8 = null,
    prompt_version: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cost_usd: ?f64 = null,
    error_message: ?[]const u8 = null,
    attributes_json: ?[]const u8 = null,
};

pub const EvalIngest = struct {
    run_id: []const u8,
    eval_key: []const u8,
    scorer: []const u8,
    score: f64,
    verdict: []const u8 = "pass",
    dataset: ?[]const u8 = null,
    notes: ?[]const u8 = null,
    metadata_json: ?[]const u8 = null,
    recorded_at_ms: ?i64 = null,
};

pub const EvalRecord = struct {
    id: []const u8,
    stored_at_ms: i64,
    run_id: []const u8,
    eval_key: []const u8,
    scorer: []const u8,
    score: f64,
    verdict: []const u8,
    dataset: ?[]const u8 = null,
    notes: ?[]const u8 = null,
    metadata_json: ?[]const u8 = null,
    recorded_at_ms: i64,
};

pub const SpanFilter = struct {
    run_id: ?[]const u8 = null,
    trace_id: ?[]const u8 = null,
    source: ?[]const u8 = null,
    operation: ?[]const u8 = null,
    status: ?[]const u8 = null,
    model: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    task_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    limit: ?usize = null,
};

pub const EvalFilter = struct {
    run_id: ?[]const u8 = null,
    verdict: ?[]const u8 = null,
    eval_key: ?[]const u8 = null,
    scorer: ?[]const u8 = null,
    dataset: ?[]const u8 = null,
    limit: ?usize = null,
};

pub const RunFilter = struct {
    run_id: ?[]const u8 = null,
    source: ?[]const u8 = null,
    operation: ?[]const u8 = null,
    status: ?[]const u8 = null,
    model: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    verdict: ?[]const u8 = null,
    dataset: ?[]const u8 = null,
    limit: ?usize = null,
};

pub const RunSummary = struct {
    run_id: []const u8,
    span_count: usize = 0,
    eval_count: usize = 0,
    error_count: usize = 0,
    total_duration_ms: f64 = 0,
    total_cost_usd: f64 = 0,
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
    pass_count: usize = 0,
    fail_count: usize = 0,
    first_seen_ms: i64 = 0,
    last_seen_ms: i64 = 0,
    overall_verdict: []const u8 = "no_evals",
};

pub const SystemSummary = struct {
    span_count: usize = 0,
    eval_count: usize = 0,
    run_count: usize = 0,
    error_count: usize = 0,
    total_duration_ms: f64 = 0,
    total_cost_usd: f64 = 0,
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
    pass_count: usize = 0,
    fail_count: usize = 0,
};

pub const RunDetail = struct {
    summary: RunSummary,
    spans: []SpanRecord,
    evals: []EvalRecord,
};

pub fn computeDurationMs(started_at_ms: i64, ended_at_ms: ?i64, explicit_duration_ms: ?f64) f64 {
    if (explicit_duration_ms) |duration| return duration;
    if (ended_at_ms) |ended| {
        if (ended <= started_at_ms) return 0;
        return @floatFromInt(ended - started_at_ms);
    }
    return 0;
}

pub fn materializeSpanRecord(
    allocator: std.mem.Allocator,
    payload: SpanIngest,
    owned_id: []const u8,
    stored_at_ms: i64,
) !SpanRecord {
    return .{
        .id = owned_id,
        .stored_at_ms = stored_at_ms,
        .run_id = try allocator.dupe(u8, payload.run_id),
        .trace_id = try allocator.dupe(u8, payload.trace_id),
        .span_id = try allocator.dupe(u8, payload.span_id),
        .parent_span_id = try dupOrNull(allocator, payload.parent_span_id),
        .source = try allocator.dupe(u8, payload.source),
        .operation = try allocator.dupe(u8, payload.operation),
        .status = try allocator.dupe(u8, payload.status),
        .started_at_ms = payload.started_at_ms,
        .ended_at_ms = payload.ended_at_ms,
        .duration_ms = computeDurationMs(payload.started_at_ms, payload.ended_at_ms, payload.duration_ms),
        .session_id = try dupOrNull(allocator, payload.session_id),
        .task_id = try dupOrNull(allocator, payload.task_id),
        .agent_id = try dupOrNull(allocator, payload.agent_id),
        .model = try dupOrNull(allocator, payload.model),
        .prompt_version = try dupOrNull(allocator, payload.prompt_version),
        .tool_name = try dupOrNull(allocator, payload.tool_name),
        .input_tokens = payload.input_tokens,
        .output_tokens = payload.output_tokens,
        .cost_usd = payload.cost_usd,
        .error_message = try dupOrNull(allocator, payload.error_message),
        .attributes_json = try dupOrNull(allocator, payload.attributes_json),
    };
}

pub fn materializeEvalRecord(
    allocator: std.mem.Allocator,
    payload: EvalIngest,
    owned_id: []const u8,
    stored_at_ms: i64,
) !EvalRecord {
    return .{
        .id = owned_id,
        .stored_at_ms = stored_at_ms,
        .run_id = try allocator.dupe(u8, payload.run_id),
        .eval_key = try allocator.dupe(u8, payload.eval_key),
        .scorer = try allocator.dupe(u8, payload.scorer),
        .score = payload.score,
        .verdict = try allocator.dupe(u8, payload.verdict),
        .dataset = try dupOrNull(allocator, payload.dataset),
        .notes = try dupOrNull(allocator, payload.notes),
        .metadata_json = try dupOrNull(allocator, payload.metadata_json),
        .recorded_at_ms = payload.recorded_at_ms orelse stored_at_ms,
    };
}

pub fn cloneSpanRecord(allocator: std.mem.Allocator, value: SpanRecord) !SpanRecord {
    return .{
        .id = try allocator.dupe(u8, value.id),
        .stored_at_ms = value.stored_at_ms,
        .run_id = try allocator.dupe(u8, value.run_id),
        .trace_id = try allocator.dupe(u8, value.trace_id),
        .span_id = try allocator.dupe(u8, value.span_id),
        .parent_span_id = try dupOrNull(allocator, value.parent_span_id),
        .source = try allocator.dupe(u8, value.source),
        .operation = try allocator.dupe(u8, value.operation),
        .status = try allocator.dupe(u8, value.status),
        .started_at_ms = value.started_at_ms,
        .ended_at_ms = value.ended_at_ms,
        .duration_ms = value.duration_ms,
        .session_id = try dupOrNull(allocator, value.session_id),
        .task_id = try dupOrNull(allocator, value.task_id),
        .agent_id = try dupOrNull(allocator, value.agent_id),
        .model = try dupOrNull(allocator, value.model),
        .prompt_version = try dupOrNull(allocator, value.prompt_version),
        .tool_name = try dupOrNull(allocator, value.tool_name),
        .input_tokens = value.input_tokens,
        .output_tokens = value.output_tokens,
        .cost_usd = value.cost_usd,
        .error_message = try dupOrNull(allocator, value.error_message),
        .attributes_json = try dupOrNull(allocator, value.attributes_json),
    };
}

pub fn cloneEvalRecord(allocator: std.mem.Allocator, value: EvalRecord) !EvalRecord {
    return .{
        .id = try allocator.dupe(u8, value.id),
        .stored_at_ms = value.stored_at_ms,
        .run_id = try allocator.dupe(u8, value.run_id),
        .eval_key = try allocator.dupe(u8, value.eval_key),
        .scorer = try allocator.dupe(u8, value.scorer),
        .score = value.score,
        .verdict = try allocator.dupe(u8, value.verdict),
        .dataset = try dupOrNull(allocator, value.dataset),
        .notes = try dupOrNull(allocator, value.notes),
        .metadata_json = try dupOrNull(allocator, value.metadata_json),
        .recorded_at_ms = value.recorded_at_ms,
    };
}

pub fn freeSpanRecord(allocator: std.mem.Allocator, value: *const SpanRecord) void {
    allocator.free(value.id);
    allocator.free(value.run_id);
    allocator.free(value.trace_id);
    allocator.free(value.span_id);
    freeOrNull(allocator, value.parent_span_id);
    allocator.free(value.source);
    allocator.free(value.operation);
    allocator.free(value.status);
    freeOrNull(allocator, value.session_id);
    freeOrNull(allocator, value.task_id);
    freeOrNull(allocator, value.agent_id);
    freeOrNull(allocator, value.model);
    freeOrNull(allocator, value.prompt_version);
    freeOrNull(allocator, value.tool_name);
    freeOrNull(allocator, value.error_message);
    freeOrNull(allocator, value.attributes_json);
}

pub fn freeEvalRecord(allocator: std.mem.Allocator, value: *const EvalRecord) void {
    allocator.free(value.id);
    allocator.free(value.run_id);
    allocator.free(value.eval_key);
    allocator.free(value.scorer);
    allocator.free(value.verdict);
    freeOrNull(allocator, value.dataset);
    freeOrNull(allocator, value.notes);
    freeOrNull(allocator, value.metadata_json);
}

fn dupOrNull(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |slice| {
        const duped = try allocator.dupe(u8, slice);
        return duped;
    }
    return null;
}

fn freeOrNull(allocator: std.mem.Allocator, value: ?[]const u8) void {
    if (value) |slice| allocator.free(slice);
}

test "computeDurationMs uses explicit duration first" {
    try std.testing.expectEqual(@as(f64, 42), computeDurationMs(1_000, 2_000, 42));
}

test "computeDurationMs derives from timestamps" {
    try std.testing.expectEqual(@as(f64, 200), computeDurationMs(500, 700, null));
}
