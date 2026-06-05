# Monolithic ROS 2 Deployment (camera + YOLO + LLaVA + Voxtral)

Single container image running the four AI nodes in one runtime unit
(see `Models/` and the chart `values.yaml` for the full node set):

- `camera_driver_pkg` publishes `/camera/image_raw`
- `yolo_detector_pkg` subscribes and publishes `/detections`
- `llava_pkg` (LLaVA-1.5-7B) for visual reasoning
- `voxtral_pkg` (Voxtral-Mini-3B) for voice interaction

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
