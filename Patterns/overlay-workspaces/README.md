# Overlay Workspaces ROS 2 Deployment

This chart deploys a ROS 2 runtime image built with two workspace layers:

1. Base workspace (`/opt/base_ws`): camera driver.
2. Overlay workspace (`/opt/overlay_ws`): YOLO detector.

The pod runs both nodes (`camera_driver` and `yolo_detector`) in one container while preserving the overlay build/deployment model.

## Usage

```bash
helm upgrade --install overlay ./helm/ros2-overlay
```
