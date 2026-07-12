#!/usr/bin/env python3
"""Bring Your Own Model template node (perception slot).

This node is a drop in replacement for the perception node of the four
deployment patterns. It works out of the box with a synthetic model, so the
whole pipeline (camera -> inference -> dashboard -> benchmark campaign) can be
validated before writing any inference code.

TO PLUG YOUR MODEL, edit exactly two methods of YoloDetector:

    load_model(self)            called once at startup
    infer(self, image_msg)      called once per processed frame

Everything else (subscriptions, benchmark instrumentation, parameters that the
charts pass on the command line) is already wired to the conventions of this
repository, so the dashboard, run_full_campaign.sh and aggregate_with_ci.py
work unchanged.
"""
import json
import time

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from sensor_msgs.msg import Image
from std_msgs.msg import Float32, String


class YoloDetector(Node):
    """Perception slot node. The class name is required by the dynamic
    pattern's plugin registry (yolo_detector_pkg::YoloDetector); your model
    does not need to be a detector."""

    def __init__(self, **kwargs):
        super().__init__('yolo_detector', **kwargs)

        # Parameters the charts pass on the launch command line. Declare all
        # of them even if your model ignores some, or the node will fail to
        # start under the stock charts.
        self.declare_parameter('model_path', '')
        self.declare_parameter('conf', 0.25)
        self.declare_parameter('image_topic', '/camera/image_raw')
        self.declare_parameter('detections_topic', '/detections')
        self.declare_parameter('debug_image_topic', '/detections/image')
        self.declare_parameter('publish_debug_image', False)
        self.declare_parameter('publish_metrics', True)
        self.declare_parameter('latency_topic', '/benchmark/latency_ms')
        self.declare_parameter('inference_topic', '/benchmark/inference_ms')
        self.declare_parameter('filter_classes', '')
        # Synthetic model knob: simulated inference time in milliseconds.
        self.declare_parameter('synthetic_inference_ms', 20.0)

        qos = QoSProfile(reliability=ReliabilityPolicy.BEST_EFFORT,
                         history=HistoryPolicy.KEEP_LAST, depth=1)
        image_topic = self.get_parameter('image_topic').value
        self.sub = self.create_subscription(Image, image_topic, self.on_image, qos)

        self.pub_det = self.create_publisher(
            String, self.get_parameter('detections_topic').value, 10)
        self.pub_latency = self.create_publisher(
            Float32, self.get_parameter('latency_topic').value, 10)
        self.pub_inference = self.create_publisher(
            Float32, self.get_parameter('inference_topic').value, 10)
        # Cumulative counters used by the drop and queue instrumentation of
        # the paper (aggregate_with_ci.py derives drop rate and queue wait).
        self.pub_frames_received = self.create_publisher(
            Float32, '/benchmark/frames_received', 10)
        self.pub_queue_wait = self.create_publisher(
            Float32, '/benchmark/queue_wait_ms', 10)

        self.frames_received = 0
        self.load_model()
        self.get_logger().info(
            f'BYOM template node ready, subscribed to {image_topic}')

    # ────────────────────────────────────────────────────────────────────
    # USER EXTENSION POINT 1 OF 2: load your weights here.
    # ────────────────────────────────────────────────────────────────────
    def load_model(self):
        """Called once at startup. Replace with your model loading code.

        Example:
            from ultralytics import YOLO
            self.model = YOLO(self.get_parameter('model_path').value)
        """
        self.model = None  # synthetic model needs no weights
        self.get_logger().info('Synthetic model loaded (replace load_model).')

    # ────────────────────────────────────────────────────────────────────
    # USER EXTENSION POINT 2 OF 2: run inference on one frame here.
    # ────────────────────────────────────────────────────────────────────
    def infer(self, image_msg):
        """Called per processed frame. Must return a JSON serialisable dict.

        image_msg is a sensor_msgs/Image. Convert it as your model needs,
        for example with cv_bridge:
            import numpy as np
            arr = np.frombuffer(image_msg.data, dtype=np.uint8)
        The synthetic implementation just sleeps for a configurable time and
        returns a fake result, so timing behaves like a real lightweight model.
        """
        time.sleep(self.get_parameter('synthetic_inference_ms').value / 1000.0)
        return {
            'model': 'synthetic-template',
            'width': image_msg.width,
            'height': image_msg.height,
            'objects': [{'label': 'placeholder', 'confidence': 0.99}],
        }

    # ────────────────────────────────────────────────────────────────────
    # Pipeline and instrumentation: no changes needed below this line.
    # ────────────────────────────────────────────────────────────────────
    def on_image(self, msg: Image):
        t_recv = time.time()
        self.frames_received += 1

        # Queue wait: time between camera stamping and callback start.
        stamp_s = msg.header.stamp.sec + msg.header.stamp.nanosec * 1e-9
        queue_wait_ms = max(0.0, (t_recv - stamp_s) * 1000.0) if stamp_s > 0 else 0.0

        t0 = time.time()
        result = self.infer(msg)
        inference_ms = (time.time() - t0) * 1000.0

        out = String()
        out.data = json.dumps(result)
        self.pub_det.publish(out)

        if self.get_parameter('publish_metrics').value:
            latency_ms = (time.time() - stamp_s) * 1000.0 if stamp_s > 0 else inference_ms
            self.pub_latency.publish(Float32(data=float(latency_ms)))
            self.pub_inference.publish(Float32(data=float(inference_ms)))
            self.pub_frames_received.publish(Float32(data=float(self.frames_received)))
            self.pub_queue_wait.publish(Float32(data=float(queue_wait_ms)))


def main(args=None):
    rclpy.init(args=args)
    node = YoloDetector()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
