import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from sensor_msgs.msg import Image
from cv_bridge import CvBridge
import cv2
import numpy as np

class CameraDriver(Node):
    """
    Lee frames de /dev/videoX y publica sensor_msgs/Image en /camera/image_raw.
    Parámetros:
      - device: path del dispositivo (default: /dev/video0)
      - width, height: resolución deseada
      - fps: tasa de publicación (usada para el temporizador)
    """
    def __init__(self):
        super().__init__('camera_driver')

        self.declare_parameter('device', '/dev/video0')
        self.declare_parameter('width', 1280)
        self.declare_parameter('height', 720)
        self.declare_parameter('fps', 30)
        self.declare_parameter('frame_id', 'camera')
        self.declare_parameter('image_topic', '/camera/image_raw')
        self.declare_parameter('synthetic_mode', False)

        qos = QoSProfile(depth=1)
        qos.reliability = ReliabilityPolicy.BEST_EFFORT
        qos.history = HistoryPolicy.KEEP_LAST

        topic = self.get_parameter('image_topic').get_parameter_value().string_value
        self.publisher = self.create_publisher(Image, topic, qos)
        self.bridge = CvBridge()

        dev = self.get_parameter('device').get_parameter_value().string_value
        w = int(self.get_parameter('width').value)
        h = int(self.get_parameter('height').value)
        self.synthetic_mode = bool(self.get_parameter('synthetic_mode').value)
        self.synthetic_counter = 0

        self.cap = None
        if not self.synthetic_mode:
            self.cap = cv2.VideoCapture(dev)
            if not self.cap.isOpened():
                self.get_logger().warn(f'No se pudo abrir {dev}, activando modo sintetico')
                self.synthetic_mode = True
                self.cap.release()
                self.cap = None
            else:
                self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, w)
                self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, h)

        fps = float(self.get_parameter('fps').value)
        self.timer = self.create_timer(max(1.0 / fps, 1e-3), self._publish_frame)
        source = 'synthetic' if self.synthetic_mode else dev
        self.get_logger().info(f'Publicando {source} -> {topic} @ {fps} FPS')

    def _synthetic_frame(self):
        w = int(self.get_parameter('width').value)
        h = int(self.get_parameter('height').value)
        frame = np.zeros((h, w, 3), dtype=np.uint8)

        x = (self.synthetic_counter * 7) % max(w, 1)
        cv2.rectangle(frame, (0, 0), (w, h), (25, 25, 25), -1)
        cv2.rectangle(frame, (x, 0), (min(x + 120, w), h), (0, 180, 255), -1)
        cv2.putText(
            frame,
            f'synthetic frame {self.synthetic_counter}',
            (20, min(h - 20, 60)),
            cv2.FONT_HERSHEY_SIMPLEX,
            1.0,
            (255, 255, 255),
            2,
            cv2.LINE_AA,
        )
        self.synthetic_counter += 1
        return frame

    def _publish_frame(self):
        if self.synthetic_mode:
            ok, frame = True, self._synthetic_frame()
        else:
            ok, frame = self.cap.read()
        if not ok:
            self.get_logger().warn('Frame drop')
            return

        msg = self.bridge.cv2_to_imgmsg(frame, encoding='bgr8')
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.header.frame_id = self.get_parameter('frame_id').get_parameter_value().string_value
        self.publisher.publish(msg)

def main():
    rclpy.init()
    node = CameraDriver()
    try:
        rclpy.spin(node)
    finally:
        if hasattr(node, 'cap') and node.cap:
            node.cap.release()
        node.destroy_node()
        rclpy.shutdown()
