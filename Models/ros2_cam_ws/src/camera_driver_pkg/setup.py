from setuptools import setup
package_name = 'camera_driver_pkg'

setup(
    name=package_name,
    version='0.1.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        ('share/' + package_name + '/launch', ['launch/camera_driver.launch.py']),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='Miguel Angel Mateo-Casali',
    maintainer_email='mmateo@cigip.upv.es',
    description='ROS 2 camera driver publishing /camera/image_raw - CIGIP',
    license='Apache-2.0',
    entry_points={
        # Standalone use: `ros2 run camera_driver_pkg camera_driver`
        # Used by monolithic, microservices, overlay-canonical patterns.
        'console_scripts': [
            'camera_driver = camera_driver_pkg.driver:main',
        ],
        # Component composition: loaded by rclpy_components container at runtime.
        # Used by dynamic-canonical pattern. Same class, different invocation.
        'rclpy_components': [
            'camera_driver_pkg::CameraDriver = camera_driver_pkg.driver:CameraDriver',
        ],
    },
)
