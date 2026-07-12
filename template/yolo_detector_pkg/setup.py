from setuptools import setup

package_name = 'yolo_detector_pkg'

setup(
    name=package_name,
    version='1.0.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    description='Bring Your Own Model template node (perception slot).',
    license='Apache-2.0',
    # Both entry points are required so the SAME package works in every
    # pattern: console_scripts covers monolithic, microservices and overlay
    # (ros2 run yolo_detector_pkg yolo_detector); rclpy_components covers the
    # dynamic pattern (plugin discovery by the component host).
    entry_points={
        'console_scripts': [
            'yolo_detector = yolo_detector_pkg.object_detection:main',
        ],
        'rclpy_components': [
            'yolo_detector_pkg::YoloDetector = yolo_detector_pkg.object_detection:YoloDetector',
        ],
    },
)
