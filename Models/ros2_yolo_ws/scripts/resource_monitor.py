#!/usr/bin/env python3
"""
Lightweight resource monitor — publishes CPU, memory & GPU usage as ROS 2
Float32 topics so the web dashboard can display them.

Uses /proc/stat, /proc/meminfo (no psutil dependency) and nvidia-smi for GPU.

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


class ResourceMonitor(Node):

    def __init__(self):
        super().__init__('resource_monitor')
        self.declare_parameter('publish_rate', 2.0)  # Hz
        rate = self.get_parameter('publish_rate').value

        self.pub_cpu = self.create_publisher(Float32, '/node/cpu_percent', 10)
        self.pub_mem = self.create_publisher(Float32, '/node/memory_percent', 10)

        # GPU — only if nvidia-smi is available
        self._has_gpu = shutil.which('nvidia-smi') is not None
        if self._has_gpu:
            self.pub_gpu = self.create_publisher(Float32, '/node/gpu_percent', 10)
            self.get_logger().info('NVIDIA GPU detected — publishing /node/gpu_percent')
        else:
            self.pub_gpu = None
            self.get_logger().info('No NVIDIA GPU detected — GPU metrics disabled')

        self._prev_idle = 0
        self._prev_total = 0
        self._read_cpu()  # seed first sample

        self.create_timer(1.0 / rate, self._tick)
        self.get_logger().info(f'Resource monitor publishing at {rate} Hz')

    # ── CPU via /proc/stat ──────────────────────────────────────
    def _read_cpu(self):
        with open('/proc/stat') as f:
            parts = f.readline().split()
        # user nice system idle iowait irq softirq steal
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

    # ── GPU via nvidia-smi ──────────────────────────────────────
    def _gpu_percent(self):
        try:
            out = subprocess.check_output(
                ['nvidia-smi',
                 '--query-gpu=utilization.gpu',
                 '--format=csv,noheader,nounits'],
                timeout=2, stderr=subprocess.DEVNULL
            ).decode().strip()
            # May return multiple GPUs — take the first
            return float(out.split('\n')[0])
        except Exception:
            return 0.0

    # ── Timer callback ──────────────────────────────────────────
    def _tick(self):
        self.pub_cpu.publish(Float32(data=float(self._cpu_percent())))
        self.pub_mem.publish(Float32(data=float(self._mem_percent())))
        if self._has_gpu:
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
