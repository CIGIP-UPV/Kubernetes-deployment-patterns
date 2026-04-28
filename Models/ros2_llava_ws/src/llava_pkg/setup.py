from setuptools import find_packages, setup
import os
from glob import glob

package_name = 'llava_pkg'

setup(
    name=package_name,
    version='1.0.0',
    packages=find_packages(exclude=['test']),
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        (os.path.join('share', package_name, 'launch'), glob('launch/*.py')),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='CIGIP-UPV',
    maintainer_email='lmoya.upv@gmail.com',
    description='LLaVA-1.5-7b visual reasoning ROS 2 node',
    license='MIT',
    tests_require=['pytest'],
    entry_points={
        'console_scripts': [
            'llava_node = llava_pkg.llava_node:main',
        ],
        'rclpy_components': [
            'llava_pkg::LlavaNode = llava_pkg.llava_node:LlavaNode',
        ],
    },
)
