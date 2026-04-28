from setuptools import setup
package_name = 'yolo_detector_pkg'

setup(
    name=package_name,
    version='0.1.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        ('share/' + package_name + '/launch', ['launch/yolo_detector.launch.py']),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='Miguel Angel Mateo-Casali',
    maintainer_email='mmateo@cigip.upv.es',
    description='Ultralytics YOLO object detector for ROS 2 - CIGIP',
    license='MIT',
    entry_points={
        'console_scripts': [
            'yolo_detector = yolo_detector_pkg.object_detection:main',
        ],
        'rclpy_components': [
            'yolo_detector_pkg::YoloDetector = yolo_detector_pkg.object_detection:YoloDetector',
        ],
    },
)
