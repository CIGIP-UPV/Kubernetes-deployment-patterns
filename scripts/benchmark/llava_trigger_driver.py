#!/usr/bin/env python3
"""
llava_trigger_driver.py — Deterministic LLaVA trigger for benchmarking.

Publishes a canned prompt to /llava/trigger every --interval seconds via
rosbridge, for --duration seconds (or until killed with SIGTERM/SIGINT).

WHY THIS EXISTS:
  LLaVA's auto-trigger only fires when YOLO detects COCO objects in view
  (_detection_cb in llava_node.py). In an unattended benchmark the camera
  often sees an empty/dark scene (e.g. cycles that run overnight), so LLaVA
  never fires and the perception+reasoning workload degenerates into a
  perception-only (YOLO) measurement. This driver makes the reasoning load
  deterministic and IDENTICAL across the four deployment patterns, so the
  runtime metrics are measured under the same multimodal contention.

  The manual trigger path (/llava/trigger -> _trigger_cb -> _run_inference)
  bypasses the detection requirement; it only needs a camera frame, which is
  always present once the camera node is up.

Usage:
  python3 llava_trigger_driver.py --rosbridge-url ws://HOST:PORT \
      --interval 30 --duration 840
"""
import argparse
import signal
import time
from urllib.parse import urlparse

import roslibpy


def main():
    p = argparse.ArgumentParser(description="Deterministic LLaVA trigger driver.")
    p.add_argument("--rosbridge-url", default="ws://158.42.104.15:31407")
    p.add_argument("--interval", type=float, default=30.0,
                   help="Seconds between triggers (matches yolo_trigger_interval_s).")
    p.add_argument("--duration", type=float, default=840.0,
                   help="Total run time in seconds (warmup + sampling + margin).")
    p.add_argument("--prompt", default=(
        "A factory robot inspects post-consumer textile garments on a conveyor. "
        "Describe the scene and report any safety concerns."))
    a = p.parse_args()

    u = urlparse(a.rosbridge_url)
    host = u.hostname or "158.42.104.15"
    port = u.port or 9090

    c = roslibpy.Ros(host=host, port=port)
    c.run()
    print(f"[trigger-driver] connected={c.is_connected} -> {host}:{port} "
          f"| interval={a.interval}s duration={a.duration}s", flush=True)

    trig = roslibpy.Topic(c, "/llava/trigger", "std_msgs/String")
    trig.advertise()
    time.sleep(1.0)  # let advertise propagate before first publish

    stop = {"flag": False}

    def _handle(signum, frame):
        stop["flag"] = True
    signal.signal(signal.SIGTERM, _handle)
    signal.signal(signal.SIGINT, _handle)

    t0 = time.time()
    n = 0
    try:
        while not stop["flag"] and (time.time() - t0) < a.duration:
            trig.publish(roslibpy.Message({"data": a.prompt}))
            n += 1
            print(f"[trigger-driver] trigger #{n} at t={time.time()-t0:.0f}s", flush=True)
            # Sleep in 1s steps so SIGTERM/duration is honoured promptly.
            slept = 0.0
            while (slept < a.interval and not stop["flag"]
                   and (time.time() - t0) < a.duration):
                time.sleep(1.0)
                slept += 1.0
    finally:
        try:
            trig.unadvertise()
        except Exception:
            pass
        c.terminate()
        print(f"[trigger-driver] done — {n} triggers sent.", flush=True)


if __name__ == "__main__":
    main()
