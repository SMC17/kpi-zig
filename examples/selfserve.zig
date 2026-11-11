//! Synthetic ordered-funnel task: a premature step must not count as conversion.
const std = @import("std");
const lib = @import("lib");
pub fn main() !void {
    const a = std.heap.page_allocator;
    const events = [_]lib.FunnelEvent{
        .{ .user_id = 1, .step = 0, .ts_unix = 1 },
        .{ .user_id = 1, .step = 1, .ts_unix = 2 },
        .{ .user_id = 2, .step = 1, .ts_unix = 1 },
        .{ .user_id = 2, .step = 0, .ts_unix = 2 },
    };
    const stats = try lib.funnelStats(a, &events, 2);
    defer a.free(stats);
    if (stats[0].users_reached != 2 or stats[1].users_reached != 1) return error.ChronologyMismatch;
    std.debug.print("fixture: entrants=2 ordered_conversions=1 conversion_rate=0.5\n", .{});
}
