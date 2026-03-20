from launch import LaunchDescription
from launch_ros.actions import Node

def generate_launch_description():
    return LaunchDescription([
        Node(
            package='camera_driver_pkg',
            executable='camera_driver',
            name='camera_driver',
            output='screen',
            parameters=[{
                'device': '/dev/video0',
                'width': 1280,
                'height': 720,
                'fps': 30,
                'frame_id': 'camera',
                'image_topic': '/camera/image_raw',
                'synthetic_mode': False
            }]
        )
    ])
