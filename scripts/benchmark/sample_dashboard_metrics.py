#!/usr/bin/env python3
"""
sample_dashboard_metrics.py — collect ROS 2 dashboard topics via rosbridge.

Connects to the dashboard's rosbridge WebSocket (default
ws://158.42.104.15:31407, the NodePort exposed on kb2) and subscribes to
the topics that the deployment patterns publish:

    /benchmark/inference_ms     std_msgs/Float32   YOLO inference time (T_inf)
    /benchmark/latency_ms       std_msgs/Float32   end-to-end latency (T_e2e)
    /llava/metrics_inference_ms std_msgs/Float32   LLaVA inference time
    /llava/metrics_latency_ms   std_msgs/Float32   LLaVA end-to-end latency
    /node/cpu_percent           std_msgs/Float32   CPU usage (U_CPU)
    /node/gpu_percent           std_msgs/Float32   GPU usage (U_GPU)
    /node/memory_percent        std_msgs/Float32   RAM usage (U_RAM)
    /node/io_read_mbs           std_msgs/Float32   Disk read (L_IO read)
    /node/io_write_mbs          std_msgs/Float32   Disk write (L_IO write)

Samples for `--duration` seconds, then writes:
    <output>             raw samples (timestamp,topic,value), one per line
    <output_aggregate>   one-row aggregate ready for the campaign comparison
                         (file path is <output> with `_samples` replaced by
                         `_aggregate`, or `dashboard_aggregate.csv` if the
                         filename matches `dashboard_samples.csv`).

Usage:
    python3 sample_dashboard_metrics.py \\
        --rosbridge-url ws://158.42.104.15:31407 \\
        --duration 180 \\
        --output dashboard_samples.csv

Dependencies:
    pip install roslibpy
    (roslibpy uses Twisted under the hood — no rclpy or ROS 2 install needed.)

If roslibpy is not available, the script exits with a clear message.
"""
from __future__ import annotations

import argparse
import csv
import os
import statistics
import sys
import time
from collections import defaultdict


TOPICS = {
    "/benchmark/inference_ms":     "std_msgs/Float32",
    "/benchmark/latency_ms":       "std_msgs/Float32",
    "/llava/metrics_inference_ms": "std_msgs/Float32",
    "/llava/metrics_latency_ms":   "std_msgs/Float32",
    "/node/cpu_percent":           "std_msgs/Float32",
    "/node/gpu_percent":           "std_msgs/Float32",
    "/node/memory_percent":        "std_msgs/Float32",
    "/node/io_read_mbs":           "std_msgs/Float32",
    "/node/io_write_mbs":          "std_msgs/Float32",
    # ── Instrumentacion de colas/descartes (revision IEEE Access, R1.10) ──
    # drop = frames_published(camera) - frames_received(yolo), calculado en
    # aggregate_with_ci.py. queue_wait_ms = latencia total - inferencia pura.
    "/camera/frames_published":    "std_msgs/Float32",
    "/benchmark/frames_received":  "std_msgs/Float32",
    "/benchmark/queue_wait_ms":    "std_msgs/Float32",
}


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--rosbridge-url", default="ws://158.42.104.15:31407",
                   help="rosbridge WebSocket URL")
    p.add_argument("--duration", type=int, default=180,
                   help="Sample window in seconds (default: 180)")
    p.add_argument("--output", default="dashboard_samples.csv",
                   help="Output CSV with raw samples (default: dashboard_samples.csv)")
    args = p.parse_args()

    # Lazy import so the script can give a friendly error if the library is
    # missing (it is not part of any standard ROS 2 install).
    try:
        import roslibpy
    except ImportError:
        print("[sampler] FATAL: roslibpy is not installed.", file=sys.stderr)
        print("[sampler]        Install it with: pip install roslibpy", file=sys.stderr)
        return 2

    # roslibpy expects host + port separately; parse the ws:// URL.
    if not args.rosbridge_url.startswith("ws://"):
        print(f"[sampler] FATAL: --rosbridge-url must start with ws:// (got {args.rosbridge_url})",
              file=sys.stderr)
        return 2
    host_port = args.rosbridge_url[len("ws://"):].split("/", 1)[0]
    if ":" in host_port:
        host, port_s = host_port.split(":", 1)
        port = int(port_s)
    else:
        host = host_port
        port = 9090

    print(f"[sampler] Connecting to rosbridge at {host}:{port}...", flush=True)
    client = roslibpy.Ros(host=host, port=port)
    client.run(timeout=20)
    if not client.is_connected:
        print("[sampler] FATAL: could not connect to rosbridge", file=sys.stderr)
        return 1

    samples: dict[str, list[tuple[float, float]]] = defaultdict(list)
    raw_writer_lock_dummy = []  # placeholder if we ever multi-thread

    def make_callback(topic_name: str):
        def _cb(message):
            value = message.get("data", None)
            if value is None:
                return
            samples[topic_name].append((time.time(), float(value)))
        return _cb

    listeners = []
    for topic, msg_type in TOPICS.items():
        t = roslibpy.Topic(client, topic, msg_type)
        t.subscribe(make_callback(topic))
        listeners.append(t)

    print(f"[sampler] Subscribed to {len(listeners)} topics. "
          f"Sampling for {args.duration}s...", flush=True)

    t_start = time.time()
    t_end = t_start + args.duration
    while time.time() < t_end:
        time.sleep(2)
        elapsed = int(time.time() - t_start)
        total = sum(len(v) for v in samples.values())
        print(f"[sampler] t+{elapsed:>4}s — total samples so far: {total}",
              flush=True)

    # Unsubscribe and disconnect cleanly.
    for t in listeners:
        try:
            t.unsubscribe()
        except Exception:
            pass
    client.terminate()
    print("[sampler] Disconnected.", flush=True)

    # ── Write raw samples ─────────────────────────────────────────────
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["timestamp_unix", "topic", "value"])
        for topic, rows in samples.items():
            for ts, val in rows:
                w.writerow([f"{ts:.3f}", topic, f"{val:.6f}"])
    print(f"[sampler] Raw samples written: {args.output} "
          f"({sum(len(v) for v in samples.values())} rows)", flush=True)

    # ── Aggregate (one-row CSV ready for the campaign comparison) ──
    def _aggregate(values: list[float]) -> dict[str, float | str]:
        if not values:
            return {"avg": "", "max": "", "min": "", "stdev": "", "n": 0}
        return {
            "avg":   statistics.mean(values),
            "max":   max(values),
            "min":   min(values),
            "stdev": statistics.stdev(values) if len(values) > 1 else 0.0,
            "n":     len(values),
        }

    inf_vals  = [v for _, v in samples["/benchmark/inference_ms"]]
    lat_vals  = [v for _, v in samples["/benchmark/latency_ms"]]
    cpu_vals  = [v for _, v in samples["/node/cpu_percent"]]
    gpu_vals  = [v for _, v in samples["/node/gpu_percent"]]
    mem_vals  = [v for _, v in samples["/node/memory_percent"]]
    ior_vals  = [v for _, v in samples["/node/io_read_mbs"]]
    iow_vals  = [v for _, v in samples["/node/io_write_mbs"]]

    inf_agg = _aggregate(inf_vals)
    lat_agg = _aggregate(lat_vals)
    cpu_agg = _aggregate(cpu_vals)
    gpu_agg = _aggregate(gpu_vals)
    mem_agg = _aggregate(mem_vals)

    # f_FPS estimate from inference timestamps spacing.
    inf_ts = [ts for ts, _ in samples["/benchmark/inference_ms"]]
    if len(inf_ts) >= 2:
        deltas = [b - a for a, b in zip(inf_ts, inf_ts[1:]) if b > a]
        f_fps = 1.0 / statistics.mean(deltas) if deltas else 0.0
    else:
        f_fps = 0.0

    # j_inf = stdev of inference latency (ms).
    j_inf = inf_agg["stdev"] if isinstance(inf_agg["stdev"], float) else ""

    # Aggregate file path: replace _samples with _aggregate (or hard-code if
    # the user passed dashboard_samples.csv literally).
    base, ext = os.path.splitext(args.output)
    if base.endswith("_samples"):
        agg_path = base[: -len("_samples")] + "_aggregate" + ext
    else:
        agg_path = base + "_aggregate" + ext

    with open(agg_path, "w", newline="") as f:
        w = csv.writer(f)
        # The campaign comparator (run_full_campaign.sh) expects this exact
        # column order:
        # t_inf_avg_ms, f_fps_avg, t_e2e_avg_ms, j_inf_ms,
        # u_cpu_avg_pct, u_gpu_avg_pct, u_ram_avg_pct
        w.writerow(["t_inf_avg_ms", "f_fps_avg", "t_e2e_avg_ms", "j_inf_ms",
                    "u_cpu_avg_pct", "u_gpu_avg_pct", "u_ram_avg_pct"])
        w.writerow([
            f'{inf_agg["avg"]:.2f}' if inf_agg["n"] else "",
            f'{f_fps:.2f}'           if f_fps       else "",
            f'{lat_agg["avg"]:.2f}' if lat_agg["n"] else "",
            f'{j_inf:.2f}'           if isinstance(j_inf, float) else "",
            f'{cpu_agg["avg"]:.2f}' if cpu_agg["n"] else "",
            f'{gpu_agg["avg"]:.2f}' if gpu_agg["n"] else "",
            f'{mem_agg["avg"]:.2f}' if mem_agg["n"] else "",
        ])
    print(f"[sampler] Aggregate written: {agg_path}", flush=True)

    # Pretty summary on stdout for the campaign log.
    def _fmt(name, agg, units=""):
        n = agg["n"]
        if not n:
            print(f"[sampler]   {name:30s}  no samples")
            return
        avg = agg["avg"]
        mx = agg["max"]
        mn = agg["min"]
        sd = agg["stdev"] if isinstance(agg["stdev"], float) else 0.0
        print(f"[sampler]   {name:30s}  n={n:>4d}  avg={avg:>8.2f}{units} "
              f"max={mx:>8.2f}{units}  min={mn:>8.2f}{units}  sd={sd:>6.2f}")

    print("[sampler] ─── summary ───")
    _fmt("YOLO inference (ms)",       inf_agg, "")
    _fmt("YOLO end-to-end (ms)",      lat_agg, "")
    _fmt("CPU (%)",                   cpu_agg, "")
    _fmt("GPU (%)",                   gpu_agg, "")
    _fmt("RAM (%)",                   mem_agg, "")
    print(f"[sampler]   {'estimated f_FPS':30s}            avg={f_fps:>8.2f} fps")
    print(f"[sampler]   {'I/O read avg (MB/s)':30s}            avg={(statistics.mean(ior_vals) if ior_vals else 0.0):>8.2f}")
    print(f"[sampler]   {'I/O write avg (MB/s)':30s}            avg={(statistics.mean(iow_vals) if iow_vals else 0.0):>8.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
