#!/usr/bin/env python3
"""
Lightweight resource monitor — publishes CPU, memory & GPU usage as ROS 2
Float32 topics so the web dashboard can display them.

Uses /proc/stat, /proc/meminfo (no psutil dependency).
GPU detection priority:
  1. nvidia-smi  (desktop/server with NVIDIA GPU)
  2. tegrastats  (Jetson Orin/Xavier — requires binary on host or in image)
  3. sysfs       (Jetson — reads /sys/devices/gpu.0/load or similar, works
                  inside containers without extra mounts if running privileged)

Published topics:
  /node/cpu_percent     (std_msgs/Float32)  — total CPU usage  0-100
  /node/memory_percent  (std_msgs/Float32)  — RAM usage        0-100
  /node/gpu_percent     (std_msgs/Float32)  — GPU utilization  0-100  (if available)
"""

import rclpy
from rclpy.node import Node
from std_msgs.msg import Float32
import subprocess
import shutil
import glob
import re
import os


class ResourceMonitor(Node):

    def __init__(self):
        super().__init__('resource_monitor')
        self.declare_parameter('publish_rate', 2.0)  # Hz
        rate = self.get_parameter('publish_rate').value

        self.pub_cpu = self.create_publisher(Float32, '/node/cpu_percent', 10)
        self.pub_mem = self.create_publisher(Float32, '/node/memory_percent', 10)

        # GPU detection order: nvidia-smi > tegrastats > sysfs
        self._gpu_method = None
        self._gpu_sysfs_path = None

        if shutil.which('nvidia-smi') is not None:
            self._gpu_method = 'nvidia-smi'
        elif shutil.which('tegrastats') is not None or os.path.exists('/usr/bin/tegrastats'):
            self._gpu_method = 'tegrastats'
        else:
            # Fallback: Jetson sysfs GPU load file
            # Typical paths:
            #   /sys/devices/platform/gpu.0/load          (Jetson Orin / Xavier)
            #   /sys/devices/platform/17000000.ga10b/load  (Jetson Orin device-tree)
            #   /sys/devices/gpu.0/load                   (older Jetsons)
            candidates = (
                glob.glob('/sys/devices/platform/*/load') +
                glob.glob('/sys/devices/platform/gpu.*/load') +
                glob.glob('/sys/devices/gpu.*/load')
            )
            for path in candidates:
                try:
                    val = open(path).read().strip()
                    # The file returns 0-1000 (per-mille) on Jetson
                    if val.isdigit():
                        self._gpu_sysfs_path = path
                        self._gpu_method = 'sysfs'
                        break
                except Exception:
                    continue

        if self._gpu_method:
            self.pub_gpu = self.create_publisher(Float32, '/node/gpu_percent', 10)
            extra = f' ({self._gpu_sysfs_path})' if self._gpu_method == 'sysfs' else ''
            self.get_logger().info(
                f'GPU detected via {self._gpu_method}{extra} — publishing /node/gpu_percent')
        else:
            self.pub_gpu = None
            self.get_logger().info(
                'No GPU tool found (nvidia-smi / tegrastats / sysfs) — GPU metrics disabled')

        self._prev_idle = 0
        self._prev_total = 0
        self._read_cpu()  # seed first sample

        self.create_timer(1.0 / rate, self._tick)
        self.get_logger().info(f'Resource monitor publishing at {rate} Hz')

    # ── CPU via /proc/stat ──────────────────────────────────────
    def _read_cpu(self):
        with open('/proc/stat') as f:
            parts = f.readline().split()
        values = [int(v) for v in parts[1:]]
        idle = values[3] + values[4]  # idle + iowait
        total = sum(values)
        return idle, total

    def _cpu_percent(self):
        idle, total = self._read_cpu()
        d_idle = idle - self._prev_idle
        d_total = total - self._prev_total
        self._prev_idle = idle
        self._prev_total = total
        if d_total == 0:
            return 0.0
        return (1.0 - d_idle / d_total) * 100.0

    # ── Memory via /proc/meminfo ────────────────────────────────
    @staticmethod
    def _mem_percent():
        info = {}
        with open('/proc/meminfo') as f:
            for line in f:
                parts = line.split()
                info[parts[0].rstrip(':')] = int(parts[1])
        total = info.get('MemTotal', 1)
        avail = info.get('MemAvailable', 0)
        return (1.0 - avail / total) * 100.0

    # ── GPU ──────────────────────────────────────────────────────
    def _gpu_percent(self):
        if self._gpu_method == 'nvidia-smi':
            return self._gpu_nvidia_smi()
        elif self._gpu_method == 'tegrastats':
            return self._gpu_tegrastats()
        elif self._gpu_method == 'sysfs':
            return self._gpu_sysfs()
        return 0.0

    def _gpu_nvidia_smi(self):
        try:
            out = subprocess.check_output(
                ['nvidia-smi',
                 '--query-gpu=utilization.gpu',
                 '--format=csv,noheader,nounits'],
                timeout=2, stderr=subprocess.DEVNULL
            ).decode().strip()
            return float(out.split('\n')[0])
        except Exception:
            return 0.0

    def _gpu_tegrastats(self):
        """Parse Jetson tegrastats for GPU utilization.
        tegrastats --interval 100 prints one line like:
          RAM 5348/7620MB ... GR3D_FREQ 78% ...
        We grab the GR3D_FREQ percentage.
        """
        try:
            proc = subprocess.run(
                ['tegrastats', '--interval', '200'],
                capture_output=True, text=True, timeout=1
            )
            line = proc.stdout.strip().split('\n')[-1] if proc.stdout else ''
            # GR3D_FREQ 45%  or  GR3D_FREQ 45%@1300
            m = re.search(r'GR3D_FREQ\s+(\d+)%', line)
            return float(m.group(1)) if m else 0.0
        except Exception:
            return 0.0

    def _gpu_sysfs(self):
        """Read Jetson GPU load from sysfs (works inside containers).
        The file returns a value 0-1000 (per-mille), divide by 10 for %.
        """
        try:
            val = open(self._gpu_sysfs_path).read().strip()
            return float(val) / 10.0
        except Exception:
            return 0.0

    # ── Timer callback ──────────────────────────────────────────
    def _tick(self):
        self.pub_cpu.publish(Float32(data=float(self._cpu_percent())))
        self.pub_mem.publish(Float32(data=float(self._mem_percent())))
        if self.pub_gpu:
            self.pub_gpu.publish(Float32(data=float(self._gpu_percent())))


def main():
    rclpy.init()
    node = ResourceMonitor()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
