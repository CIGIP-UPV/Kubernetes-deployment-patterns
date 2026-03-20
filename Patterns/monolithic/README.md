# Monolithic ROS 2 Deployment (Camera + YOLO)

Single container image running both ROS 2 nodes in one runtime unit:

- `camera_driver_pkg` publishes `/camera/image_raw`
- `yolo_detector_pkg` subscribes and publishes `/detections`

## Deploy

```bash
helm upgrade --install mono ./helm \
  --set image.repository=<registry>/ros2-monolithic \
  --set image.tag=<tag>
```

## Notes

- By default it mounts `/dev/video0` from the host.
- It publishes latency/inference metrics to:
  - `/benchmark/latency_ms`
  - `/benchmark/inference_ms`
