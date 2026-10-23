/// Pure-Dart summarization of collected frame and input-latency samples.
///
/// This layer owns the statistics contract only. It never imports Flutter so
/// the numbers can be unit tested without an engine, and so the same
/// percentile definition is shared by every rendered-input evidence lane.
library;

/// Nearest-rank percentile over an already sorted ascending sample list.
///
/// Matches the definition frozen by
/// `EditorRenderedInputSampleProtocol.nearestRankStatistic` so rendered-input
/// latency and frame-time evidence stay directly comparable.
int nearestRankPercentile(List<int> sortedSamples, double rank) {
  if (sortedSamples.isEmpty) {
    throw ArgumentError.value(
      sortedSamples,
      'sortedSamples',
      'must not be empty',
    );
  }
  final index = (rank * sortedSamples.length).ceil() - 1;
  return sortedSamples[index.clamp(0, sortedSamples.length - 1)];
}

/// Summary of one collected frame-timing window.
final class FrameTimingStatistics {
  const FrameTimingStatistics({
    required this.sampleCount,
    required this.warmupFrameCount,
    required this.budgetMicros,
    required this.buildMedianMicros,
    required this.buildP95Micros,
    required this.buildMaxMicros,
    required this.rasterMedianMicros,
    required this.rasterP95Micros,
    required this.rasterMaxMicros,
    required this.totalSpanMedianMicros,
    required this.totalSpanP95Micros,
    required this.totalSpanMaxMicros,
    required this.vsyncOverheadP95Micros,
    required this.overBudgetFrameCount,
    required this.skippedBudgetFrameCount,
  });

  final int sampleCount;
  final int warmupFrameCount;
  final int budgetMicros;
  final int buildMedianMicros;
  final int buildP95Micros;
  final int buildMaxMicros;
  final int rasterMedianMicros;
  final int rasterP95Micros;
  final int rasterMaxMicros;
  final int totalSpanMedianMicros;
  final int totalSpanP95Micros;
  final int totalSpanMaxMicros;
  final int vsyncOverheadP95Micros;

  /// Frames whose end-to-end span exceeded the real display budget.
  final int overBudgetFrameCount;

  /// Frames where UI work plus raster work exceeded two budgets, which is the
  /// only drop signal `FrameTiming` can support without engine timeline data.
  final int skippedBudgetFrameCount;

  double get overBudgetFrameRatio =>
      sampleCount == 0 ? 0 : overBudgetFrameCount / sampleCount;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'sampleCount': sampleCount,
      'warmupFrameCount': warmupFrameCount,
      'budgetMicros': budgetMicros,
      'buildMedianMicros': buildMedianMicros,
      'buildP95Micros': buildP95Micros,
      'buildMaxMicros': buildMaxMicros,
      'rasterMedianMicros': rasterMedianMicros,
      'rasterP95Micros': rasterP95Micros,
      'rasterMaxMicros': rasterMaxMicros,
      'totalSpanMedianMicros': totalSpanMedianMicros,
      'totalSpanP95Micros': totalSpanP95Micros,
      'totalSpanMaxMicros': totalSpanMaxMicros,
      'vsyncOverheadP95Micros': vsyncOverheadP95Micros,
      'overBudgetFrameCount': overBudgetFrameCount,
      'overBudgetFrameRatio': overBudgetFrameRatio,
      'skippedBudgetFrameCount': skippedBudgetFrameCount,
    };
  }
}

/// Summarizes the four parallel `FrameTiming` series collected for one run.
FrameTimingStatistics summarizeFrameTimings({
  required List<int> buildMicros,
  required List<int> rasterMicros,
  required List<int> totalSpanMicros,
  required List<int> vsyncOverheadMicros,
  required int warmupFrameCount,
  required int budgetMicros,
}) {
  if (budgetMicros <= 0) {
    throw ArgumentError.value(
      budgetMicros,
      'budgetMicros',
      'must be positive',
    );
  }
  final lengths = <int>{
    buildMicros.length,
    rasterMicros.length,
    totalSpanMicros.length,
    vsyncOverheadMicros.length,
  };
  if (lengths.length != 1) {
    throw ArgumentError.value(
      lengths,
      'frame series',
      'build, raster, total span and vsync overhead must share one length',
    );
  }
  final start = warmupFrameCount.clamp(0, buildMicros.length);
  if (start >= buildMicros.length) {
    throw ArgumentError.value(
      warmupFrameCount,
      'warmupFrameCount',
      'must leave at least one measured frame',
    );
  }
  final build = List<int>.from(buildMicros.sublist(start))..sort();
  final raster = List<int>.from(rasterMicros.sublist(start))..sort();
  final total = List<int>.from(totalSpanMicros.sublist(start))..sort();
  final vsync = List<int>.from(vsyncOverheadMicros.sublist(start))..sort();

  final measured = build.length;
  var overBudget = 0;
  var skippedBudget = 0;
  for (var index = 0; index < measured; index += 1) {
    if (totalSpanMicros[start + index] > budgetMicros) {
      overBudget += 1;
    }
    final combined =
        buildMicros[start + index] + rasterMicros[start + index];
    if (combined > budgetMicros * 2) {
      skippedBudget += 1;
    }
  }

  return FrameTimingStatistics(
    sampleCount: measured,
    warmupFrameCount: start,
    budgetMicros: budgetMicros,
    buildMedianMicros: nearestRankPercentile(build, 0.50),
    buildP95Micros: nearestRankPercentile(build, 0.95),
    buildMaxMicros: build.last,
    rasterMedianMicros: nearestRankPercentile(raster, 0.50),
    rasterP95Micros: nearestRankPercentile(raster, 0.95),
    rasterMaxMicros: raster.last,
    totalSpanMedianMicros: nearestRankPercentile(total, 0.50),
    totalSpanP95Micros: nearestRankPercentile(total, 0.95),
    totalSpanMaxMicros: total.last,
    vsyncOverheadP95Micros: nearestRankPercentile(vsync, 0.95),
    overBudgetFrameCount: overBudget,
    skippedBudgetFrameCount: skippedBudget,
  );
}

/// Summary of one input-latency series such as keystroke to presented frame.
final class LatencyStatistics {
  const LatencyStatistics({
    required this.sampleCount,
    required this.budgetMicros,
    required this.medianMicros,
    required this.p95Micros,
    required this.maxMicros,
    required this.overBudgetCount,
  });

  final int sampleCount;
  final int budgetMicros;
  final int medianMicros;
  final int p95Micros;
  final int maxMicros;
  final int overBudgetCount;

  double get overBudgetRatio =>
      sampleCount == 0 ? 0 : overBudgetCount / sampleCount;

  bool get withinBudget => overBudgetCount == 0;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'sampleCount': sampleCount,
      'budgetMicros': budgetMicros,
      'medianMicros': medianMicros,
      'p95Micros': p95Micros,
      'maxMicros': maxMicros,
      'overBudgetCount': overBudgetCount,
      'overBudgetRatio': overBudgetRatio,
      'withinBudget': withinBudget,
    };
  }
}

/// Summarizes an already post-warmup latency series.
LatencyStatistics summarizeLatencies(
  List<int> latencyMicros, {
  required int budgetMicros,
}) {
  if (budgetMicros <= 0) {
    throw ArgumentError.value(
      budgetMicros,
      'budgetMicros',
      'must be positive',
    );
  }
  if (latencyMicros.isEmpty) {
    throw ArgumentError.value(
      latencyMicros,
      'latencyMicros',
      'must not be empty',
    );
  }
  final sorted = List<int>.from(latencyMicros)..sort();
  return LatencyStatistics(
    sampleCount: sorted.length,
    budgetMicros: budgetMicros,
    medianMicros: nearestRankPercentile(sorted, 0.50),
    p95Micros: nearestRankPercentile(sorted, 0.95),
    maxMicros: sorted.last,
    overBudgetCount: sorted.where((value) => value > budgetMicros).length,
  );
}
