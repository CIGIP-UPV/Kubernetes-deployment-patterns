# Dynamic Module Loading (Camera + YOLO)

This pattern runs:

- a static camera node (`camera_driver_pkg`), and
- a dynamic host API that can load/unload the YOLO node at runtime.

## Deploy

```bash
helm upgrade --install dyn ./helm/dynamic-loader \
  --set images.camera.repository=<registry>/ros2-camera \
  --set images.camera.tag=<tag> \
  --set images.dynamicHost.repository=<registry>/ros2-yolo \
  --set images.dynamicHost.tag=<tag>
```

## Dynamic API

- `GET /health`
- `GET /status`
- `POST /modules/load/yolo_detector`
- `POST /modules/unload/yolo_detector`

By default (`dynamic.autoLoadYolo=true`) the module is loaded on startup for benchmark reproducibility.
