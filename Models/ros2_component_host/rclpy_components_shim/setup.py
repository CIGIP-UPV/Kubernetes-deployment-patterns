from setuptools import setup

package_name = 'rclpy_components'

setup(
    name=package_name,
    version='0.1.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages',
            ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='Miguel-Angel-Mateo-Casali',
    maintainer_email='mmateo@cigip.upv.es',
    description='Minimal local rclpy_components for Humble (component_container_isolated).',
    license='Apache-2.0',
    entry_points={
        'console_scripts': [
            'component_container = rclpy_components.component_container:main',
            'component_container_isolated = rclpy_components.component_container:main',
        ],
    },
)
