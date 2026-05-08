# Benchmark Metrics — monolithic

_Generated: 2026-05-04T11:11:14Z by collect_metrics.sh_

Release: `mono-pattern`  ·  Namespace: `ros2exp`

## S_img — Image footprint

| Image | Size (GB) | Bytes |
|-------|-----------|-------|
| ros2-monolithic | 29.76 | 31957852708 |
| ros2-dashboard | 0.24 | 262935865 |
| **TOTAL** | **30.01** | **32220788573** |

## T_sched — Scheduling latency (per pod)

| Pod | Δ (s) | Scheduled | Started |
|-----|-------|-----------|---------|

## L_net — Round-trip latency

| Node | IP | RTT avg (ms) |
|------|------|--------------|
| kb2 | 158.42.104.15 | 4.202 |
| edgenode01 | 158.42.104.206 | 7.865 |
| worker1-kb2 | 158.42.104.103 | 30.404 |

_Bandwidth (iperf3) must be measured manually._

## C_cfg — Config churn

_(no diff or no tags)_

## T_CI — Last successful build

Duration: `n/a` seconds

## Derived

| Indicator | Value |
|-----------|-------|
| T_ready (from dashboard) | 0.76 s |
| η_start | n/a |
| R_deploy | n/a |
