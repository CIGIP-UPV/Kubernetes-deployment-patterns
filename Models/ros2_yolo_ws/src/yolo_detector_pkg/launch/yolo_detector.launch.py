from launch import LaunchDescription
from launch_ros.actions import Node

def generate_launch_description():
    return LaunchDescription([
        Node(
            package='yolo_detector_pkg',
            executable='yolo_detector',
            name='yolo_detector',
            output='screen',
            parameters=[{
                'model_path': 'yolov8n.pt',       # cambia a yolov8s.pt si tienes más GPU
                'conf': 0.25,
                'image_topic': '/camera/image_raw',
                'publish_debug_image': True
            }]
        )
    ])
