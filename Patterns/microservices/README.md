# ROS 2 Microservices Deployment (camera + YOLO + LLaVA + Voxtral)

Each AI node runs as an independent microservice (plus the dashboard),
communicating over CycloneDDS. See `values.yaml` for the full image set:

- `camera` service (edge): publishes `/camera/image_raw`
- `yolo` service (edge): subscribes and publishes `/detections`
- `llava` service (edge): LLaVA-1.5-7B visual reasoning
- `voxtral` service (edge): Voxtral-Mini-3B voice interaction
- `dashboard` service (cloud): rosbridge control panel

## Deploy

```bash
helm upgrade --install micro ./helm/ros2-microservices \
  --set images.camera.repository=<registry>/ros2-camera --set images.camera.tag=<tag> \
  --set images.yolo.repository=<registry>/ros2-yolo --set images.yolo.tag=<tag> \
  --set images.llava.repository=<registry>/ros2-llava --set images.llava.tag=<tag> \
  --set images.voxtral.repository=<registry>/ros2-voxtral --set images.voxtral.tag=<tag>
```

## Notes

- Node placement is configurable via the per-service `nodeSelector` values.
- Metrics are published to `/benchmark/latency_ms` and `/benchmark/inference_ms`.
