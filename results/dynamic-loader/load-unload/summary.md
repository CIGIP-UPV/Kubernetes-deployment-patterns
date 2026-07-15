# dynamic-loader — C-7 load/unload latency

_Captured: 2026-07-14T14:19:00Z_

Release: `dynamic-pattern`  ·  Namespace: `ros2exp`

## Per-module results

| Module | Load (s) | Unload (s) | Load status | Unload status |
|--------|----------|------------|-------------|---------------|
| yolo | 0.28 | 90.28 | FAIL | FAIL |
| llava | 0.49 | 0.51 | FAIL | FAIL |
| voxtral | 0.51 | 0.52 | FAIL | FAIL |

## Comparison context

These are the times the operator pays to **swap a single AI module**
without restarting the pod. For comparison:

| Pattern | Time to swap one model |
|---------|------------------------|
| monolithic | ~15-25 min (rebuild image + push + pull + boot) |
| microservices | ~5-10 min (rebuild ONE microservice + push + pull) |
| overlay | ~16 min cold-cold, ~2.5 min cold-ish (re-extract overlay) |
| **dynamic-loader** | **load_s + unload_s seconds** ⭐ |

## Files in this run

- load_unload_per_module.csv
- summary.md
