import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/perf/frame_timing_statistics.dart';

void main() {
  group('nearestRankPercentile', () {
    test('uses the nearest-rank definition shared with rendered input', () {
      final samples = <int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10];

      expect(nearestRankPercentile(samples, 0.50), 5);
      expect(nearestRankPercentile(samples, 0.95), 10);
      expect(nearestRankPercentile(<int>[7], 0.95), 7);
    });

    test('rejects an empty sample', () {
      expect(
        () => nearestRankPercentile(<int>[], 0.5),
        throwsArgumentError,
      );
    });
  });

  group('summarizeFrameTimings', () {
    test('drops warmup frames and reports nearest-rank percentiles', () {
      final statistics = summarizeFrameTimings(
        buildMicros: <int>[999, 1, 2, 3, 4, 5],
        rasterMicros: <int>[999, 1, 2, 3, 4, 5],
        totalSpanMicros: <int>[999, 2, 4, 6, 8, 10],
        vsyncOverheadMicros: <int>[999, 0, 0, 0, 0, 0],
        warmupFrameCount: 1,
        budgetMicros: 16,
      );

      expect(statistics.warmupFrameCount, 1);
      expect(statistics.sampleCount, 5);
      expect(statistics.buildMedianMicros, 3);
      expect(statistics.buildP95Micros, 5);
      expect(statistics.buildMaxMicros, 5);
      expect(statistics.totalSpanMedianMicros, 6);
      expect(statistics.totalSpanMaxMicros, 10);
    });

    test('counts frames over the real display budget', () {
      final statistics = summarizeFrameTimings(
        buildMicros: <int>[4, 4, 4],
        rasterMicros: <int>[4, 4, 4],
        totalSpanMicros: <int>[8, 17, 33],
        vsyncOverheadMicros: <int>[0, 0, 0],
        warmupFrameCount: 0,
        budgetMicros: 16,
      );

      expect(statistics.overBudgetFrameCount, 2);
      expect(statistics.overBudgetFrameRatio, closeTo(2 / 3, 1e-9));
      expect(statistics.skippedBudgetFrameCount, 0);
    });

    test('flags a skipped budget when UI plus raster exceed two budgets', () {
      final statistics = summarizeFrameTimings(
        buildMicros: <int>[20],
        rasterMicros: <int>[20],
        totalSpanMicros: <int>[20],
        vsyncOverheadMicros: <int>[0],
        warmupFrameCount: 0,
        budgetMicros: 16,
      );

      expect(statistics.skippedBudgetFrameCount, 1);
    });

    test('rejects mismatched series lengths', () {
      expect(
        () => summarizeFrameTimings(
          buildMicros: <int>[1, 2],
          rasterMicros: <int>[1],
          totalSpanMicros: <int>[1, 2],
          vsyncOverheadMicros: <int>[1, 2],
          warmupFrameCount: 0,
          budgetMicros: 16,
        ),
        throwsArgumentError,
      );
    });

    test('rejects a warmup that consumes every frame', () {
      expect(
        () => summarizeFrameTimings(
          buildMicros: <int>[1],
          rasterMicros: <int>[1],
          totalSpanMicros: <int>[1],
          vsyncOverheadMicros: <int>[0],
          warmupFrameCount: 1,
          budgetMicros: 16,
        ),
        throwsArgumentError,
      );
    });

    test('rejects a non-positive budget', () {
      expect(
        () => summarizeFrameTimings(
          buildMicros: <int>[1],
          rasterMicros: <int>[1],
          totalSpanMicros: <int>[1],
          vsyncOverheadMicros: <int>[0],
          warmupFrameCount: 0,
          budgetMicros: 0,
        ),
        throwsArgumentError,
      );
    });

    test('serializes every reported metric', () {
      final statistics = summarizeFrameTimings(
        buildMicros: <int>[1],
        rasterMicros: <int>[1],
        totalSpanMicros: <int>[2],
        vsyncOverheadMicros: <int>[0],
        warmupFrameCount: 0,
        budgetMicros: 16,
      );

      expect(statistics.toJson(), <String, Object?>{
        'sampleCount': 1,
        'warmupFrameCount': 0,
        'budgetMicros': 16,
        'buildMedianMicros': 1,
        'buildP95Micros': 1,
        'buildMaxMicros': 1,
        'rasterMedianMicros': 1,
        'rasterP95Micros': 1,
        'rasterMaxMicros': 1,
        'totalSpanMedianMicros': 2,
        'totalSpanP95Micros': 2,
        'totalSpanMaxMicros': 2,
        'vsyncOverheadP95Micros': 0,
        'overBudgetFrameCount': 0,
        'overBudgetFrameRatio': 0,
        'skippedBudgetFrameCount': 0,
      });
    });
  });

  group('summarizeLatencies', () {
    test('reports median, p95, max and budget ratio', () {
      final statistics = summarizeLatencies(
        <int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 40],
        budgetMicros: 16,
      );

      expect(statistics.sampleCount, 10);
      expect(statistics.medianMicros, 5);
      expect(statistics.p95Micros, 40);
      expect(statistics.maxMicros, 40);
      expect(statistics.overBudgetCount, 1);
      expect(statistics.overBudgetRatio, closeTo(0.1, 1e-9));
      expect(statistics.withinBudget, isFalse);
    });

    test('passes when every sample stays inside the budget', () {
      final statistics = summarizeLatencies(
        <int>[4000, 6000, 8000],
        budgetMicros: 16000,
      );

      expect(statistics.withinBudget, isTrue);
    });

    test('rejects an empty series', () {
      expect(
        () => summarizeLatencies(<int>[], budgetMicros: 16),
        throwsArgumentError,
      );
    });
  });
}
