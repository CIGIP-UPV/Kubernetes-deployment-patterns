#!/usr/bin/env python3
"""
Lightweight resource monitor — publishes CPU, memory, GPU, I/O and Power usage
as ROS 2 Float32 topics so the web dashboard can display them.

Uses /proc/stat, /proc/meminfo, /proc/diskstats (no psutil dependency).
GPU detection priority:
  1. nvidia-smi  (desktop/server with NVIDIA GPU)
  2. tegrastats  (Jetson Orin/Xavier — requires binary on host or in image)
  3. sysfs       (Jetson — reads /sys/devices/gpu.0/load or similar)

Published topics:
  /node/cpu_percent     (std_msgs/Float32)  — total CPU usage  0-100
  /node/memory_percent  (std_msgs/Float32)  — RAM usage        0-100
  /node/gpu_percent     (std_msgs/Float32)  — GPU utilization  0-100  (if avail)
  /node/io_read_mbs     (std_msgs/Float32)  — disk read MB/s   (from /proc/diskstats)
  /node/io_write_mbs    (std_msgs/Float32)  — disk write MB/s
  /node/power_mw        (std_msgs/Float32)  — total power draw mW (Jetson tegrastats)
"""

import rclpy
from rclpy.node import Node
from std_msgs.msg import Float32
import subprocess
import shutil
import glob
import re
import os
import threading
import time


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
            # Verify nvidia-smi can report utilization (Jetson returns [N/A])
            try:
                _test = subprocess.check_output(
                    ['nvidia-smi', '--query-gpu=utilization.gpu',
                     '--format=csv,noheader,nounits'],
                    timeout=2, stderr=subprocess.DEVNULL
                ).decode().strip()
                float(_test.split('\n')[0])  # raises if [N/A]
                self._gpu_method = 'nvidia-smi'
            except Exception:
                self._gpu_method = None  # fall through to sysfs
        if self._gpu_method is None and (shutil.which('tegrastats') is not None or os.path.exists('/usr/bin/tegrastats')):
            self._gpu_method = 'tegrastats'
        if self._gpu_method is None:
            # Fallback: Jetson sysfs GPU load file
            # JetPack 6 / L4T R36 (Orin) device-tree paths vary:
            #   /sys/devices/platform/gpu.0/load
            #   /sys/devices/platform/17000000.ga10b/load
            #   /sys/devices/platform/bus@0/17000000.ga10b/load  (nested bus)
            #   /sys/devices/gpu.0/load                          (older Jetsons)
            # Also try devfreq load nodes:
            #   /sys/devices/platform/17000000.ga10b/devfreq/17000000.ga10b/load
            candidates = (
                glob.glob('/sys/devices/platform/*/load') +
                glob.glob('/sys/devices/platform/bus@*/*/load') +
                glob.glob('/sys/devices/platform/*/devfreq/*/load') +
                glob.glob('/sys/devices/platform/bus@*/*/devfreq/*/load') +
                glob.glob('/sys/devices/platform/gpu.*/load') +
                glob.glob('/sys/devices/gpu.*/load')
            )
            # Filter: only paths that contain 'gpu' or 'ga10b' (Orin GPU)
            gpu_candidates = [p for p in candidates
                              if 'gpu' in p.lower() or 'ga10b' in p]
            # If no gpu-specific matches, try all candidates
            search_list = gpu_candidates if gpu_candidates else candidates
            for path in search_list:
                try:
                    val = open(path).read().strip()
                    # The file returns 0-1000 (per-mille) on Jetson
                    if val.isdigit():
                        self._gpu_sysfs_path = path
                        self._gpu_method = 'sysfs'
                        break
                except Exception:
                    continue
            # Log all scanned paths for debugging
            if not self._gpu_method:
                self.get_logger().warn(
                    f'sysfs GPU scan found {len(candidates)} candidates: '
                    + ', '.join(candidates[:10]) if candidates else 'none')

        if self._gpu_method:
            self.pub_gpu = self.create_publisher(Float32, '/node/gpu_percent', 10)
            extra = f' ({self._gpu_sysfs_path})' if self._gpu_method == 'sysfs' else ''
            self.get_logger().info(
                f'GPU detected via {self._gpu_method}{extra} — publishing /node/gpu_percent')
        else:
            self.pub_gpu = None
            self.get_logger().info(
                'No GPU tool found (nvidia-smi / tegrastats / sysfs) — GPU metrics disabled')

        # ── I/O publishers (always on; reads /proc/diskstats) ──
        self.pub_io_read = self.create_publisher(Float32, '/node/io_read_mbs', 10)
        self.pub_io_write = self.create_publisher(Float32, '/node/io_write_mbs', 10)
        self._prev_io_read_sec = 0
        self._prev_io_write_sec = 0
        self._prev_io_ts = time.time()
        try:
            r, w = self._read_diskstats_total_sectors()
            self._prev_io_read_sec, self._prev_io_write_sec = r, w
            self.get_logger().info('I/O monitor enabled (/proc/diskstats)')
        except Exception as e:
            self.get_logger().warn(f'I/O monitor disabled: {e}')

        # ── Power publisher (Jetson via tegrastats Popen, lazy start) ──
        # tegrastats prints continuously; we run a background thread that reads
        # one line at a time, parses VDD_IN power, and stores latest sample.
        self.pub_power = None
        self._power_mw = None
        if shutil.which('tegrastats') is not None or os.path.exists('/usr/bin/tegrastats'):
            self.pub_power = self.create_publisher(Float32, '/node/power_mw', 10)
            self._power_thread_stop = threading.Event()
            self._power_thread = threading.Thread(target=self._power_loop, daemon=True)
            self._power_thread.start()
            self.get_logger().info('Power monitor enabled (tegrastats)')
        else:
            self.get_logger().info('No tegrastats found — power metrics disabled')

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

    # ── I/O via /proc/diskstats ─────────────────────────────────
    @staticmethod
    def _read_diskstats_total_sectors():
        """Sum read_sectors and write_sectors across all real block devices.
        Skips loop, ram, dm-* (noisy or virtual). Returns (read_sec, write_sec).
        Sector = 512 bytes on Linux (regardless of physical sector size).
        """
        read_sec = 0
        write_sec = 0
        with open('/proc/diskstats') as f:
            for line in f:
                parts = line.split()
                if len(parts) < 14:
                    continue
                dev = parts[2]
                # Skip virtual / noisy devices.
                if dev.startswith(('loop', 'ram', 'dm-', 'zram')):
                    continue
                # Skip partitions (sd[a-z][0-9], nvme0n1p1, mmcblk0p1, etc.) by
                # heuristic: name ends with a digit AND has a parent without it.
                # Simpler: just include majors we care about. We rely on the
                # whole-disk lines (they include partition I/O too on most kernels).
                # To avoid double-counting, prefer top-level devices only.
                if dev[-1].isdigit() and not dev.startswith('nvme'):
                    # Likely a partition (sda1, mmcblk0p1). Skip — sda already covers it.
                    if any(dev.startswith(prefix) for prefix in ('sd', 'mmcblk', 'hd')):
                        continue
                try:
                    read_sec += int(parts[5])
                    write_sec += int(parts[9])
                except ValueError:
                    continue
        return read_sec, write_sec

    def _io_mbs(self):
        """Compute MB/s read and write since last call."""
        try:
            r, w = self._read_diskstats_total_sectors()
            now = time.time()
            dt = now - self._prev_io_ts
            if dt <= 0:
                return 0.0, 0.0
            dr = max(0, r - self._prev_io_read_sec)
            dw = max(0, w - self._prev_io_write_sec)
            self._prev_io_read_sec = r
            self._prev_io_write_sec = w
            self._prev_io_ts = now
            # 512 bytes/sector → MB/s = sectors * 512 / (1024*1024) / dt
            mb_per_sector = 512.0 / (1024.0 * 1024.0)
            return (dr * mb_per_sector) / dt, (dw * mb_per_sector) / dt
        except Exception:
            return 0.0, 0.0

    # ── Power via tegrastats background thread ──────────────────
    def _power_loop(self):
        """Spawn tegrastats and parse VDD_IN power for total board draw.
        Sample tegrastats output line:
          RAM 5348/15876MB ... VDD_IN 5350mW/5350mW ... GR3D_FREQ 78%@1300 ...
        Some Jetsons publish multiple power rails (VDD_CPU_CV, VDD_SOC, etc.);
        VDD_IN is the total board power.
        """
        try:
            proc = subprocess.Popen(
                ['tegrastats', '--interval', '1000'],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True
            )
            pat_vdd_in = re.compile(r'VDD_IN\s+(\d+)mW')
            pat_pom_5v = re.compile(r'POM_5V_IN\s+(\d+)/')  # older Jetsons
            while not self._power_thread_stop.is_set():
                line = proc.stdout.readline()
                if not line:
                    time.sleep(0.5)
                    continue
                m = pat_vdd_in.search(line) or pat_pom_5v.search(line)
                if m:
                    self._power_mw = float(m.group(1))
        except Exception as e:
            try:
                self.get_logger().warn(f'tegrastats power loop error: {e}')
            except Exception:
                pass

    # ── Timer callback ──────────────────────────────────────────
    def _tick(self):
        self.pub_cpu.publish(Float32(data=float(self._cpu_percent())))
        self.pub_mem.publish(Float32(data=float(self._mem_percent())))
        if self.pub_gpu:
            self.pub_gpu.publish(Float32(data=float(self._gpu_percent())))
        # I/O
        r_mbs, w_mbs = self._io_mbs()
        self.pub_io_read.publish(Float32(data=float(r_mbs)))
        self.pub_io_write.publish(Float32(data=float(w_mbs)))
        # Power (only if we got a sample)
        if self.pub_power is not None and self._power_mw is not None:
            self.pub_power.publish(Float32(data=float(self._power_mw)))


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
