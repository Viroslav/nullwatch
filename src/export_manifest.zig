const std = @import("std");

pub fn run() !void {
    const manifest =
        \\{
        \\  "schema_version": 1,
        \\  "name": "nullwatch",
        \\  "display_name": "NullWatch",
        \\  "description": "Headless observability, tracing, evals, and run intelligence for nullclaw",
        \\  "icon": "pulse",
        \\  "repo": "nullclaw/nullwatch",
        \\  "platforms": {
        \\    "aarch64-macos": { "asset": "nullwatch-macos-aarch64.bin", "binary": "nullwatch" },
        \\    "x86_64-macos": { "asset": "nullwatch-macos-x86_64.bin", "binary": "nullwatch" },
        \\    "x86_64-linux": { "asset": "nullwatch-linux-x86_64.bin", "binary": "nullwatch" },
        \\    "aarch64-linux": { "asset": "nullwatch-linux-aarch64.bin", "binary": "nullwatch" },
        \\    "riscv64-linux": { "asset": "nullwatch-linux-riscv64.bin", "binary": "nullwatch" },
        \\    "x86_64-windows": { "asset": "nullwatch-windows-x86_64.exe", "binary": "nullwatch.exe" },
        \\    "aarch64-windows": { "asset": "nullwatch-windows-aarch64.exe", "binary": "nullwatch.exe" }
        \\  },
        \\  "build_from_source": {
        \\    "zig_version": "0.15.2",
        \\    "command": "zig build -Doptimize=ReleaseSmall",
        \\    "output": "zig-out/bin/nullwatch"
        \\  },
        \\  "launch": { "command": "nullwatch", "args": ["serve"] },
        \\  "health": { "endpoint": "/health", "port_from_config": "port" },
        \\  "ports": [{ "name": "api", "config_key": "port", "default": 7710, "protocol": "http" }],
        \\  "wizard": { "steps": [
        \\    { "id": "port", "title": "API Port", "type": "number", "required": true, "default_value": "7710", "options": [] },
        \\    { "id": "api_token", "title": "API Token", "description": "Optional bearer token for write/query API access", "type": "secret", "required": false, "options": [] },
        \\    { "id": "data_dir", "title": "Data Directory", "description": "Directory for nullwatch JSONL storage files", "type": "text", "required": true, "default_value": "data", "options": [] },
        \\    { "id": "host", "title": "Bind Host", "description": "IP address to bind the HTTP API to", "type": "text", "required": false, "default_value": "127.0.0.1", "advanced": true, "options": [] }
        \\  ] },
        \\  "depends_on": [],
        \\  "connects_to": [
        \\    { "component": "nullclaw", "role": "telemetry-source", "description": "Ingest OTLP traces emitted by nullclaw runtime observers" },
        \\    { "component": "nulltickets", "role": "task-context", "description": "Attach tracker ids and pipeline context to runs" },
        \\    { "component": "nullboiler", "role": "strategy-context", "description": "Attach orchestration strategy/version metadata to runs" }
        \\  ]
        \\}
    ;

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(manifest);
    try stdout.writeAll("\n");
}
