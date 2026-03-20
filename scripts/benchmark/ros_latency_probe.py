#!/usr/bin/env python3
import argparse
import csv
import functools
import json
import math
import time
from statistics import mean

import rclpy
from rclpy.node import Node
from std_msgs.msg import Float32


class MetricsProbe(Node):
    def __init__(self, topics: dict[str, str]):
        super().__init__("metrics_probe")
        self.samples = {name: [] for name in topics}
        self.timestamps = {name: [] for name in topics}
        for name, topic in topics.items():
            self.create_subscription(Float32, topic, functools.partial(self._cb, name), 100)

    def _cb(self, name: str, msg: Float32) -> None:
        now = time.time()
        self.timestamps[name].append(now)
        self.samples[name].append(float(msg.data))


def percentile(values, p):
    if not values:
        return math.nan
    ordered = sorted(values)
    k = (len(ordered) - 1) * p
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return ordered[int(k)]
    d0 = ordered[f] * (c - k)
    d1 = ordered[c] * (k - f)
    return d0 + d1


def summarize(values, timestamps):
    if not values:
        return {
            "samples": 0,
            "avg_ms": None,
            "p50_ms": None,
            "p95_ms": None,
            "jitter_p95_p50_ms": None,
            "first_sample_unix": None,
            "last_sample_unix": None,
        }

    p50 = percentile(values, 0.50)
    p95 = percentile(values, 0.95)
    return {
        "samples": len(values),
        "avg_ms": mean(values),
        "p50_ms": p50,
        "p95_ms": p95,
        "jitter_p95_p50_ms": p95 - p50,
        "first_sample_unix": timestamps[0],
        "last_sample_unix": timestamps[-1],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="ROS2 benchmark probe")
    parser.add_argument("--latency-topic", default="/benchmark/latency_ms")
    parser.add_argument("--inference-topic", default="/benchmark/inference_ms")
    parser.add_argument("--duration", type=int, default=180)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--summary", required=True)
    args = parser.parse_args()

    rclpy.init()
    node = MetricsProbe(
        {
            "latency": args.latency_topic,
            "inference": args.inference_topic,
        }
    )
    start = time.time()
    end = start + args.duration

    while rclpy.ok() and time.time() < end:
        rclpy.spin_once(node, timeout_sec=0.2)

    elapsed = max(time.time() - start, 1e-6)
    summary = {
        "elapsed_s": elapsed,
        "latency": summarize(node.samples["latency"], node.timestamps["latency"]),
        "inference": summarize(node.samples["inference"], node.timestamps["inference"]),
    }

    for name in ("latency", "inference"):
        output_path = f"{args.output_dir}/{name}.csv"
        with open(output_path, "w", newline="", encoding="utf-8") as fh:
            writer = csv.writer(fh)
            writer.writerow(["recv_unix", f"{name}_ms"])
            for i, value in enumerate(node.samples[name]):
                writer.writerow([node.timestamps[name][i], value])

    latency_samples = summary["latency"]["samples"]
    summary["effective_fps"] = latency_samples / elapsed if latency_samples else 0.0

    with open(args.summary, "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2)

    print(json.dumps(summary))
    node.destroy_node()
    rclpy.shutdown()


if __name__ == "__main__":
    main()
