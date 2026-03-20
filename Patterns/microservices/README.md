# ROS 2 Microservices Deployment (Camera + YOLO)

Two microservices are deployed independently:

- `camera` service (edge): publishes `/camera/image_raw`
- `yolo` service (cloud/edge): subscribes and publishes `/detections`

## Deploy

```bash
helm upgrade --install micro ./helm/ros2-microservices \
  --set images.camera.repository=<registry>/ros2-camera \
  --set images.camera.tag=<tag> \
  --set images.yolo.repository=<registry>/ros2-yolo \
  --set images.yolo.tag=<tag>
```

## Notes

- Node placement is configurable via `camera.nodeSelector` and `yolo.nodeSelector`.
- Metrics are published to `/benchmark/latency_ms` and `/benchmark/inference_ms`.
