# Performance Baseline

**Purpose:** Record Vityo performance baselines for regression detection.

## Rendered editor input (REQ-INPUT-004)

- **Protocol:** req-input-004-v1
- **Platform family:** desktop-macos
- **Status:** passed
- **Viewport:** 1200×800
- **JSON projection:** `docs/review/performance-baseline.json`
## Lane summary

| Fixture | Operation | Substitution | Evidence | Degradation | Median µs | P95 µs | Rendered lines | Status |
| --- | --- | --- | --- | --- | ---: | ---: | ---: | --- |
| 10000 | typing | off | renderedProfile | viewportBounded | 3891 | 7494 | 21 | passed |
| 10000 | typing | on | renderedProfile | viewportBounded | 3148 | 5390 | 21 | passed |
| 10000 | compositionUpdate | off | renderedProfile | viewportBounded | 2021 | 2378 | 21 | passed |
| 10000 | compositionUpdate | on | renderedProfile | viewportBounded | 1822 | 2288 | 21 | passed |
| 10000 | compositionCommit | off | renderedProfile | viewportBounded | 1852 | 2259 | 21 | passed |
| 10000 | compositionCommit | on | renderedProfile | viewportBounded | 1983 | 2280 | 21 | passed |
| 10000 | multiCursorMovement | off | renderedProfile | viewportBounded | 3268 | 5631 | 17 | passed |
| 10000 | multiCursorMovement | on | renderedProfile | viewportBounded | 2703 | 3488 | 17 | passed |
| 10000 | rectangularProjection | off | renderedProfile | viewportBounded | 1316 | 1793 | 17 | passed |
| 10000 | rectangularProjection | on | renderedProfile | viewportBounded | 1464 | 1768 | 17 | passed |
| 10000 | viewportMovement | off | renderedProfile | viewportBounded | 2646 | 3177 | 22 | passed |
| 10000 | viewportMovement | on | renderedProfile | viewportBounded | 2763 | 3636 | 21 | passed |
| 100000 | typing | off | renderedProfile | largeFileReducedDecorations | 1539 | 2007 | 21 | passed |
| 100000 | typing | on | renderedProfile | largeFileReducedDecorations | 1636 | 1996 | 21 | passed |
| 100000 | compositionUpdate | off | renderedProfile | largeFileReducedDecorations | 1140 | 1350 | 21 | passed |
| 100000 | compositionUpdate | on | renderedProfile | largeFileReducedDecorations | 1198 | 1534 | 21 | passed |
| 100000 | compositionCommit | off | renderedProfile | largeFileReducedDecorations | 1456 | 1830 | 21 | passed |
| 100000 | compositionCommit | on | renderedProfile | largeFileReducedDecorations | 1536 | 1911 | 21 | passed |
| 100000 | multiCursorMovement | off | renderedProfile | largeFileReducedDecorations | 1979 | 2455 | 17 | passed |
| 100000 | multiCursorMovement | on | renderedProfile | largeFileReducedDecorations | 2087 | 2586 | 17 | passed |
| 100000 | rectangularProjection | off | renderedProfile | largeFileReducedDecorations | 1069 | 1393 | 17 | passed |
| 100000 | rectangularProjection | on | renderedProfile | largeFileReducedDecorations | 1155 | 1513 | 17 | passed |
| 100000 | viewportMovement | off | renderedProfile | largeFileReducedDecorations | 2288 | 2824 | 21 | passed |
| 100000 | viewportMovement | on | renderedProfile | largeFileReducedDecorations | 2982 | 3723 | 21 | passed |

## Reproduce

```sh
cd products/vityo_app
flutter test --no-pub --dart-define=VITYO_RENDERED_INPUT_PROFILE=true --dart-define=VITYO_WRITE_RENDERED_INPUT_BASELINE=true test/editor_rendered_input_profile_widget_test.dart
```

Rendered profile evidence requires a declared desktop host. The profile widget test measures real editor frames and writes sanitized baseline evidence.
