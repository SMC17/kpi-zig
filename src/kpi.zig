//! kpi — cohort retention, funnels, growth accounting, RFM in Zig 0.16.
//!
//! Ports the analytical-patterns + KPIs-and-experimentation modules
//! from Zach Wilson's DataExpert.io intermediate-bootcamp (sections
//! I1–I4 + G2 in the castle inventory) to a single-binary substrate.
//! Inputs are slices of typed events / users; outputs are typed
//! aggregates. No Pandas, no Python startup, no allocator on the
//! summary functions.

const std = @import("std");

// --- I1. Cohort retention -------------------------------------------------

/// One row of user activity at a daily grain.
pub const ActivityDay = struct {
    user_id: u64,
    signup_day: u32, // days-since-epoch of the user's signup
    active_day: u32, // days-since-epoch on which the activity happened
};

/// N-day retention point: of the users whose signup_day was D days ago,
/// what fraction were active on day `signup_day + n`?
pub const RetentionPoint = struct {
    day_offset: u32, // n in "n-day retention"
    cohort_size: u32, // users in the cohort
    retained: u32, // users active on signup_day + day_offset
    retention: f64, // retained / cohort_size, 0.0 if cohort_size == 0
};

/// Compute retention curve for a single cohort (all users sharing
/// `cohort_signup_day`). `max_offset_days` controls how far the curve
/// extends. Caller owns the returned slice.
pub fn retentionCurve(
    allocator: std.mem.Allocator,
    activities: []const ActivityDay,
    cohort_signup_day: u32,
    max_offset_days: u32,
) ![]RetentionPoint {
    // 1) Find the user-set in the cohort.
    var cohort_set: std.AutoHashMap(u64, void) = .init(allocator);
    defer cohort_set.deinit();
    for (activities) |a| {
        if (a.signup_day == cohort_signup_day) try cohort_set.put(a.user_id, {});
    }
    const cohort_size: u32 = @intCast(cohort_set.count());

    // 2) For each offset, count distinct users in the cohort active
    //    on signup_day + offset.
    const out = try allocator.alloc(RetentionPoint, max_offset_days + 1);
    var seen_per_offset: std.AutoHashMap(u64, void) = .init(allocator);
    defer seen_per_offset.deinit();

    var off: u32 = 0;
    while (off <= max_offset_days) : (off += 1) {
        seen_per_offset.clearRetainingCapacity();
        const target_day: u32 = cohort_signup_day + off;
        for (activities) |a| {
            if (a.active_day == target_day and cohort_set.contains(a.user_id)) {
                try seen_per_offset.put(a.user_id, {});
            }
        }
        const retained: u32 = @intCast(seen_per_offset.count());
        const retention: f64 = if (cohort_size == 0) 0.0 else @as(f64, @floatFromInt(retained)) / @as(f64, @floatFromInt(cohort_size));
        out[off] = .{
            .day_offset = off,
            .cohort_size = cohort_size,
            .retained = retained,
            .retention = retention,
        };
    }
    return out;
}

// --- I2. Funnel analysis --------------------------------------------------

/// Funnel step event. Steps are zero-indexed; a user must complete
/// step `i` (in order) before counting toward step `i+1`.
pub const FunnelEvent = struct {
    user_id: u64,
    step: u8,
    ts_unix: i64,
};

pub const FunnelStepStat = struct {
    step: u8,
    users_reached: u32,
    pct_of_top: f64, // users_reached / users_in_step_0
};

/// Funnel conversion summary. Each step's count is "distinct users
/// who completed *this* step and all prior steps in order." Drop-off
/// between step `i` and `i+1` = `stats[i].users_reached - stats[i+1].users_reached`.
pub fn funnelStats(
    allocator: std.mem.Allocator,
    events: []const FunnelEvent,
    num_steps: u8,
) ![]FunnelStepStat {
    // For each user, find the highest contiguous step they reached,
    // walking from step 0 upward; out-of-order events count only
    // toward their declared step if all prior steps were also seen.
    var user_max: std.AutoHashMap(u64, u8) = .init(allocator);
    defer user_max.deinit();
    var user_steps: std.AutoHashMap(u64, u64) = .init(allocator); // user_id → bitmask of steps seen
    defer user_steps.deinit();

    for (events) |e| {
        if (e.step >= num_steps) continue;
        const gop = try user_steps.getOrPut(e.user_id);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* |= @as(u64, 1) << @intCast(e.step);
    }

    var it = user_steps.iterator();
    while (it.next()) |kv| {
        var s: u8 = 0;
        var contiguous: u8 = 0;
        while (s < num_steps) : (s += 1) {
            if ((kv.value_ptr.* & (@as(u64, 1) << @intCast(s))) != 0) {
                contiguous = s + 1; // user reached step s
            } else break;
        }
        if (contiguous > 0) try user_max.put(kv.key_ptr.*, contiguous - 1);
    }

    const stats = try allocator.alloc(FunnelStepStat, num_steps);
    var step: u8 = 0;
    while (step < num_steps) : (step += 1) {
        var count: u32 = 0;
        var it2 = user_max.iterator();
        while (it2.next()) |kv| {
            if (kv.value_ptr.* >= step) count += 1;
        }
        stats[step] = .{ .step = step, .users_reached = count, .pct_of_top = 0.0 };
    }
    if (stats.len > 0 and stats[0].users_reached > 0) {
        const top: f64 = @floatFromInt(stats[0].users_reached);
        for (stats) |*s| s.pct_of_top = @as(f64, @floatFromInt(s.users_reached)) / top;
    }
    return stats;
}

// --- I3. Growth accounting ------------------------------------------------

/// Growth-accounting decomposition between two periods.
pub const GrowthDecomposition = struct {
    new_users: u32, // active this period, never active before
    resurrected: u32, // active this period, active some prior period (not last)
    retained: u32, // active this period AND last period
    churned: u32, // active last period, not this period
    last_period_total: u32,
    this_period_total: u32,

    pub fn delta(self: GrowthDecomposition) i32 {
        return @as(i32, @intCast(self.this_period_total)) - @as(i32, @intCast(self.last_period_total));
    }
};

/// Compute the four-bucket decomposition over `(last_period, this_period)`.
/// `prior_active_users` are users who were active in any earlier period
/// (excluding `last_period`). Sets may overlap arbitrarily; the function
/// classifies each user against the canonical buckets.
pub fn growthDecomposition(
    allocator: std.mem.Allocator,
    last_period_active: []const u64,
    this_period_active: []const u64,
    prior_active: []const u64,
) !GrowthDecomposition {
    var last_set: std.AutoHashMap(u64, void) = .init(allocator);
    defer last_set.deinit();
    var prior_set: std.AutoHashMap(u64, void) = .init(allocator);
    defer prior_set.deinit();
    for (last_period_active) |u| try last_set.put(u, {});
    for (prior_active) |u| try prior_set.put(u, {});

    var d: GrowthDecomposition = .{
        .new_users = 0,
        .resurrected = 0,
        .retained = 0,
        .churned = 0,
        .last_period_total = @intCast(last_set.count()),
        .this_period_total = @intCast(this_period_active.len),
    };

    var this_set: std.AutoHashMap(u64, void) = .init(allocator);
    defer this_set.deinit();
    for (this_period_active) |u| try this_set.put(u, {});
    d.this_period_total = @intCast(this_set.count());

    var it_this = this_set.keyIterator();
    while (it_this.next()) |u| {
        const in_last = last_set.contains(u.*);
        const in_prior = prior_set.contains(u.*);
        if (in_last) {
            d.retained += 1;
        } else if (in_prior) {
            d.resurrected += 1;
        } else {
            d.new_users += 1;
        }
    }

    var it_last = last_set.keyIterator();
    while (it_last.next()) |u| {
        if (!this_set.contains(u.*)) d.churned += 1;
    }

    return d;
}

// --- I4. RFM segmentation -------------------------------------------------

pub const Customer = struct {
    user_id: u64,
    last_order_day: u32,
    order_count: u32,
    total_spend_cents: u64,
};

pub const RfmScore = struct {
    user_id: u64,
    r: u8, // 1..5 (5 = most recent)
    f: u8, // 1..5 (5 = most frequent)
    m: u8, // 1..5 (5 = highest monetary)

    pub fn segment(self: RfmScore) []const u8 {
        if (self.r >= 4 and self.f >= 4 and self.m >= 4) return "champion";
        if (self.r >= 4 and self.f <= 2) return "new";
        if (self.r <= 2 and self.f >= 4) return "at_risk";
        if (self.r <= 2 and self.f <= 2) return "lost";
        return "active";
    }
};

/// Bucket customers into 1..5 quintiles per R, F, M dimension. `today`
/// is the reference day for "recency." Caller owns the returned slice.
pub fn rfmQuintiles(
    allocator: std.mem.Allocator,
    customers: []const Customer,
    today: u32,
) ![]RfmScore {
    const n: usize = customers.len;
    if (n == 0) return try allocator.alloc(RfmScore, 0);

    // Build sortable arrays of (recency_days_ago, freq, monetary).
    const r_vals = try allocator.alloc(u32, n);
    defer allocator.free(r_vals);
    const f_vals = try allocator.alloc(u32, n);
    defer allocator.free(f_vals);
    const m_vals = try allocator.alloc(u64, n);
    defer allocator.free(m_vals);
    for (customers, 0..) |c, i| {
        r_vals[i] = if (today > c.last_order_day) today - c.last_order_day else 0;
        f_vals[i] = c.order_count;
        m_vals[i] = c.total_spend_cents;
    }

    const r_sorted = try allocator.dupe(u32, r_vals);
    defer allocator.free(r_sorted);
    const f_sorted = try allocator.dupe(u32, f_vals);
    defer allocator.free(f_sorted);
    const m_sorted = try allocator.dupe(u64, m_vals);
    defer allocator.free(m_sorted);

    std.mem.sort(u32, r_sorted, {}, std.sort.asc(u32));
    std.mem.sort(u32, f_sorted, {}, std.sort.asc(u32));
    std.mem.sort(u64, m_sorted, {}, std.sort.asc(u64));

    const out = try allocator.alloc(RfmScore, n);
    for (customers, 0..) |c, i| {
        // Recency: lower days_ago is BETTER → invert so quintile 5 = most recent.
        const r_q: u8 = 6 - quintile(u32, r_vals[i], r_sorted);
        const f_q: u8 = quintile(u32, f_vals[i], f_sorted);
        const m_q: u8 = quintile(u64, m_vals[i], m_sorted);
        out[i] = .{ .user_id = c.user_id, .r = r_q, .f = f_q, .m = m_q };
    }
    return out;
}

fn quintile(comptime T: type, value: T, sorted: []const T) u8 {
    if (sorted.len == 0) return 1;
    // Position of `value` in the sorted array → quintile via N/5 chunks.
    // Use binary search for the upper bound.
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (sorted[mid] <= value) lo = mid + 1 else hi = mid;
    }
    const pos: usize = lo - 1;
    const q: u8 = @intCast(@min(@as(usize, 5), pos * 5 / sorted.len + 1));
    return q;
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "retentionCurve on three-user cohort matches hand calc" {
    const alloc = testing.allocator;
    const acts = [_]ActivityDay{
        .{ .user_id = 1, .signup_day = 100, .active_day = 100 },
        .{ .user_id = 2, .signup_day = 100, .active_day = 100 },
        .{ .user_id = 3, .signup_day = 100, .active_day = 100 },
        // Day 1: 2 of 3 active.
        .{ .user_id = 1, .signup_day = 100, .active_day = 101 },
        .{ .user_id = 2, .signup_day = 100, .active_day = 101 },
        // Day 7: only user 1.
        .{ .user_id = 1, .signup_day = 100, .active_day = 107 },
    };
    const curve = try retentionCurve(alloc, &acts, 100, 7);
    defer alloc.free(curve);
    try testing.expectEqual(@as(u32, 3), curve[0].cohort_size);
    try testing.expectEqual(@as(u32, 3), curve[0].retained);
    try testing.expectEqual(@as(u32, 2), curve[1].retained);
    try testing.expectEqual(@as(u32, 1), curve[7].retained);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), curve[7].retention, 1e-9);
}

test "funnelStats counts only contiguous-from-zero users" {
    const alloc = testing.allocator;
    const events = [_]FunnelEvent{
        // user 1 hits 0,1,2 — top of funnel
        .{ .user_id = 1, .step = 0, .ts_unix = 0 },
        .{ .user_id = 1, .step = 1, .ts_unix = 1 },
        .{ .user_id = 1, .step = 2, .ts_unix = 2 },
        // user 2 hits 0,1 — half funnel
        .{ .user_id = 2, .step = 0, .ts_unix = 0 },
        .{ .user_id = 2, .step = 1, .ts_unix = 1 },
        // user 3 hits 2 only — skips, must not count for step 2
        .{ .user_id = 3, .step = 2, .ts_unix = 0 },
    };
    const stats = try funnelStats(alloc, &events, 3);
    defer alloc.free(stats);
    try testing.expectEqual(@as(u32, 2), stats[0].users_reached);
    try testing.expectEqual(@as(u32, 2), stats[1].users_reached);
    try testing.expectEqual(@as(u32, 1), stats[2].users_reached);
}

test "growthDecomposition four-bucket" {
    const alloc = testing.allocator;
    const last = [_]u64{ 1, 2, 3 };
    const this_period = [_]u64{ 2, 3, 4, 5 }; // 4=new, 5=resurrected, 2+3=retained, 1=churned
    const prior = [_]u64{ 5, 6 };

    const d = try growthDecomposition(alloc, &last, &this_period, &prior);
    try testing.expectEqual(@as(u32, 1), d.new_users); // 4
    try testing.expectEqual(@as(u32, 1), d.resurrected); // 5
    try testing.expectEqual(@as(u32, 2), d.retained); // 2, 3
    try testing.expectEqual(@as(u32, 1), d.churned); // 1
    try testing.expectEqual(@as(i32, 1), d.delta()); // 4 - 3
}

test "rfmQuintiles labels champion and lost" {
    const alloc = testing.allocator;
    const customers = [_]Customer{
        .{ .user_id = 1, .last_order_day = 99, .order_count = 50, .total_spend_cents = 50_000_00 }, // champion-ish
        .{ .user_id = 2, .last_order_day = 50, .order_count = 1, .total_spend_cents = 100 }, // lost-ish
        .{ .user_id = 3, .last_order_day = 98, .order_count = 25, .total_spend_cents = 25_000_00 },
        .{ .user_id = 4, .last_order_day = 70, .order_count = 5, .total_spend_cents = 5_000_00 },
        .{ .user_id = 5, .last_order_day = 95, .order_count = 10, .total_spend_cents = 10_000_00 },
    };
    const scores = try rfmQuintiles(alloc, &customers, 100);
    defer alloc.free(scores);
    try testing.expectEqual(@as(usize, 5), scores.len);
    // user 1 should be top-quintile across R/F/M; user 2 should be bottom.
    var champ: ?RfmScore = null;
    var loser: ?RfmScore = null;
    for (scores) |s| {
        if (s.user_id == 1) champ = s;
        if (s.user_id == 2) loser = s;
    }
    try testing.expect(champ.?.r >= 4 and champ.?.f == 5 and champ.?.m == 5);
    try testing.expect(loser.?.r <= 2 and loser.?.f == 1 and loser.?.m == 1);
}

test "RfmScore.segment names buckets" {
    const champion: RfmScore = .{ .user_id = 0, .r = 5, .f = 5, .m = 5 };
    try testing.expectEqualStrings("champion", champion.segment());
    const lost: RfmScore = .{ .user_id = 0, .r = 1, .f = 1, .m = 1 };
    try testing.expectEqualStrings("lost", lost.segment());
    const new_user: RfmScore = .{ .user_id = 0, .r = 5, .f = 1, .m = 1 };
    try testing.expectEqualStrings("new", new_user.segment());
    const at_risk: RfmScore = .{ .user_id = 0, .r = 1, .f = 5, .m = 5 };
    try testing.expectEqualStrings("at_risk", at_risk.segment());
}
