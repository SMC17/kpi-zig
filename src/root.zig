const kpi = @import("kpi.zig");

pub const ActivityDay = kpi.ActivityDay;
pub const RetentionPoint = kpi.RetentionPoint;
pub const retentionCurve = kpi.retentionCurve;

pub const FunnelEvent = kpi.FunnelEvent;
pub const FunnelStepStat = kpi.FunnelStepStat;
pub const funnelStats = kpi.funnelStats;

pub const GrowthDecomposition = kpi.GrowthDecomposition;
pub const growthDecomposition = kpi.growthDecomposition;

pub const Customer = kpi.Customer;
pub const RfmScore = kpi.RfmScore;
pub const rfmQuintiles = kpi.rfmQuintiles;

test {
    @import("std").testing.refAllDecls(@This());
}
