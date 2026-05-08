# Kubernetes ROS 2 Deployment Patterns

This repository provides four deployment patterns for running ROS 2 (Humble) applications on K3s with load simulation and monitoring hooks.

- **Monolithic deployment** — Single container image with multiple ROS 2 nodes launched together. Simpler to ship; lowest internal messaging overhead; least modular for updates.
- **Microservices deployment** — Separate containers per capability (e.g., perception, inference, navigation), orchestrated via Kubernetes/Helm; enables independent scaling and fault isolation.
- **Dynamic module loading (ROS 2 composition)** — Runtime loading/unloading of component nodes into a component manager; exposes control endpoints to compose functionality on the fly.
- **Overlay workspaces** — Deliver new/updated ROS 2 packages as overlays on top of a stable base, minimizing rebuilds and enabling fast feature rollouts.

Each pattern includes:
- a **workload generator** (configurable via env vars / `values.yaml`) to simulate camera frames and inference load, and
- **observability hooks** (Prometheus/Grafana) for runtime metrics.


## Architecture overview

The four patterns share a common topology. The Jetson AGX Orin acts as
the edge node hosting the GPU-accelerated inference pipeline, while one
or two amd64 nodes host the dashboard and the optional carrier
extraction Job that the overlay-canonical pattern uses.

```
                   K3s cluster
   ┌──────────────────────────────────────────────────────────────────────────┐
   │                                                                          │
   │   Cloud (kb2 / worker1-kb2, amd64)        Edge (edgenode01, Jetson Orin) │
   │   ┌──────────────────────────┐            ┌──────────────────────┐       │
   │   │  ros2-dashboard          │  ROS 2     │  runtime pod (GPU)   │       │
   │   │   rosbridge + nginx      │ ◀────────▶ │   • camera_driver    │       │
   │   │                          │  topics    │   • yolo_detector    │       │
   │   │  overlay-server (nginx)  │            │   • llava_node       │       │
   │   │   only in overlay-       │  HTTP      │   • voxtral_node     │       │
   │   │   canonical              │ ◀────────▶ │  resource_monitor    │       │
   │   └──────────────────────────┘  sync      └──────────────────────┘       │
   │                                                                          │
   └──────────────────────────────────────────────────────────────────────────┘
       RMW: rmw_cyclonedds_cpp                     Jetson AGX Orin 64 GB
       ROS_DOMAIN_ID: 42                           JetPack 6.1 / CUDA 12.6
                                                   cuDNN 9.x
```

**Hardware & software stack used in the IEEE Access experiments**:

| Component | Spec |
|---|---|
| Edge node | NVIDIA Jetson AGX Orin 64 GB, JetPack 6.1 (L4T R36.4.0) |
| Cloud worker | amd64 server (kb2), Ubuntu 22.04 |
| Cluster | K3s with `runtimeClassName: nvidia` for GPU access |
| ROS 2 | Humble Hawksbill, RMW: CycloneDDS |
| Container registry | GitLab Container Registry (CIGIP-UPV) |
| Tooling | Helm 3.16+, kubectl 1.30+, docker buildx |
| AI models | YOLOv8n (3.2 M params), LLaVA-1.5-7B FP16, Voxtral-Mini-3B |



## Deployment Patterns

1. Monolithic Container

- **Pros**: simplest shipping; no inter-container ROS overhead; low intra-process latency.
- **Cons**: large image footprint; coarse-grained updates; limited fault isolation.
- **Instructions**: A single container image includes the full ROS 2 application stack, namely the camera driver, the YOLO inference node, and the detection output pipeline.
This pattern is appropriate when operational simplicity is the main priority and the full application is updated as a unit.
Deployment is performed through one Kubernetes Deployment and one runtime image, which minimizes orchestration complexity and simplifies debugging.
However, any application change requires rebuilding and redeploying the whole image, even if only one internal component is modified.
In this work, the monolithic pattern is used as the baseline reference against which the remaining patterns are compared.

  **Helm install**:
  ```bash
  helm install mono-pattern Patterns/monolithic/helm \
    --namespace ros2exp --create-namespace \
    --set image.tag=latest \
    --set camera.device=/dev/video1
  ```


2. Microservices

- **Pros**: per-service scaling; independent updates; stronger isolation/least-privilege.
- **Cons**: more moving parts; network overhead between nodes; requires DevOps discipline.
- **Instructions**: Application functionality is split into independent services, typically separating the camera producer and the YOLO inference component into different containers and Kubernetes workloads.
Each service can be deployed, monitored, restarted, and updated independently, which improves modularity and operational flexibility.
This pattern is particularly suitable when compute-intensive inference should be scheduled on different hardware than sensing components, for example separating edge acquisition from cloud-side processing.
The main trade-off is the additional communication overhead introduced by inter-service ROS 2 traffic, together with increased deployment and observability complexity.
In this study, the microservices pattern represents the most decoupled and orchestrated form of deployment.

  **Helm install**:
  ```bash
  helm install micro-pattern Patterns/microservices/helm/ros2-microservices \
    --namespace ros2exp --create-namespace \
    --set image.tag=latest \
    --set camera.device=/dev/video1
  ```


3. Dynamic Module Loading (ROS 2 Composition)

- **Pros**: runtime reconfiguration; fast iteration; shared process memory (reduced IPC).
- **Cons**: weaker isolation across dynamically loaded components; secure loading policy required.
- **Instructions**: The system starts from a host runtime that can load or unload functional modules dynamically during execution without rebuilding the complete application image.
In the evaluated setup, the inference component is managed dynamically while the camera pipeline remains continuously active.
This approach is useful for rapid experimentation, adaptive functionality, and runtime feature management, since modules can be activated or replaced with minimal service interruption.
Its main limitation is reduced isolation, because dynamically loaded components share a common execution environment and therefore require stricter control over module trust, lifecycle, and error handling.
In this work, the dynamic loading pattern is used to evaluate the trade-off between deployment agility and runtime robustness.

  **Helm install** (canonical realisation under
  `Patterns/dynamic-canonical/`, using `component_container_isolated`
  with `LoadNode`/`UnloadNode` services):
  ```bash
  helm install dynamic-pattern Patterns/dynamic-canonical/helm/ros2-dynamic-canonical \
    --namespace ros2exp --create-namespace \
    --set image.tag=latest \
    --set camera.device=/dev/video1
  ```


4. Overlay Workspaces

- **Pros**: small incremental updates; keep base immutable; fast rollouts of models/features.
- **Cons**: dependency boundaries must be curated; overlay depth should stay shallow.
- **Instructions**: A stable base workspace contains the common ROS 2 dependencies and foundational packages, while an overlay workspace contains the components that evolve more frequently, such as inference nodes or model-related logic.
This organization allows small incremental updates to be delivered without rebuilding the entire software stack, reducing rollout time and image churn.
The pattern is especially useful when the lower layers of the application remain stable but upper-layer functionality changes often during experimentation or iterative development.
Its effectiveness depends on maintaining clear dependency boundaries between base and overlay layers; otherwise, the workspace structure becomes difficult to maintain and reproduce.
In this study, overlay workspaces are used to assess the benefits of incremental delivery and controlled software evolution in Kubernetes-based ROS 2 systems.

  **Helm install** (canonical realisation under
  `Patterns/overlay-canonical/`, with an immutable `ros2-base` image and
  a mutable `ros2-overlay-pack` carrier extracted into a PVC):
  ```bash
  helm install over-pattern Patterns/overlay-canonical/helm/ros2-overlay-canonical \
    --namespace ros2exp --create-namespace \
    --set images.base.tag=latest \
    --set images.overlayPack.tag=latest \
    --set camera.device=/dev/video1
  ```


## Benchmarking metrics
The following metrics are collected for benchmarking:

### Benchmark Metrics Overview

| **Category** | **Metric** | **Symbol**           | **Brief Description**                                                     | **Measurement Procedure / Tools**                                                                            |
|---------------|-------------|----------------------|---------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| **Packaging & Distribution** | **Image footprint** | $S_{\text{img}}$     | Total container image size including all layers (GB).                     | `docker image inspect <image> --format '{{.Size}}'`                                                          |
| **Deployment & Setup** | **Cold installation time** | $T_{\text{install}}$ | Time from `helm install` command to completion of initial deployment (s). | Timestamp before/after `helm upgrade --install`                                                              |
| **Deployment & Setup** | **App readiness time** | $T_{\text{ready}}$   | Time between `helm start` and first ROS 2 message received.               | Collected from an add-hoc ROS 2 probe (first message timestamp).                                             |
| **Runtime Performance** | **Inference time (avg)** | $T_{\text{inf}}$     | Mean end-to-end inference latency per frame (ms).                         | Collected from ROS 2 detection message timestamps (`header.stamp` vs receive time).                          |
| **Runtime Performance** | **Frame rate** | $f_{\text{FPS}}$     | Number of processed frames per second during steady state.                | Measured by ROS 2 probe (inference timestamps).                                                              |
| **Runtime Performance** | **Jitter** | $J_{\text{inf}}$     | Variability of inference latency (p95–p50 or std. dev.).                  | Derived from latency distribution captured in ROS 2 probe logs.                                              |
| **Runtime Performance** | **CPU usage** | $U_{\text{CPU}}$     | Average and max CPU utilization (%) per container.                        | `docker stats` / `kubectl top pods` sampled in `22_runtime_stats.sh`.                                        |
| **Runtime Performance** | **GPU usage** | $U_{\text{GPU}}$     | Average and max GPU compute utilization (%).                              | `tegrastats` (Jetson).                                                                                       |
| **Runtime Performance** | **I/O load** | $L_{\text{IO}}$      | Disk read/write throughput during app execution (MB/s).                   | `iostat -xm 1` or `docker stats` I/O columns; aggregated per second.                                         |
| **Energy Efficiency** | **Power consumption** | $P_{\text{avg}}$     | Average electrical power drawn by device during inference (W).            | `tegrastats`; integrate over runtime.                                                                        |
| **Energy Efficiency** | **Energy per inference** | $E_{\text{inf}}$     | Energy cost per processed frame (J/frame).                                | $E_{\text{inf}} = P_{\text{avg}} \times t_{\text{run}} / N_{\text{frames}}\); derived from power + FPS logs. |
| **Network & Scheduling** | **Network latency** | $L_{\text{net}}$     | Round-trip latency or bandwidth delay between edge and cloud (ms).        | `ping`, `iperf3`, or `tc qdisc show`; can be injected via `tc netem`.                                        |
| **Network & Scheduling** | **Scheduling latency** | $T_{\text{sched}}$   | Time from pod creation to container start (s).                            | Extract from `kubectl get events` (`Scheduled`→`Started`) or `kubectl describe pod`.                         |
| **DevOps & Maintainability** | **Config churn** | $C_{\text{cfg}}$     | Number of changed lines/files per update cycle.                           | `git diff --stat` between consecutive Helm values/config commits.                                            |
| **DevOps & Maintainability** | **CI pipeline time** | $T_{\text{CI}}$      | Duration of automated build-test-deploy pipeline (min).                   | CI job logs (GitHub Actions / Jenkins / GitLab CI) → total runtime per commit.                               |


---

### Optional Derived Indicators

| **Indicator** | **Formula / Meaning**                                                                                             |
|----------------|-------------------------------------------------------------------------------------------------------------------|
| **Startup efficiency** | $\eta_{\text{start}} = 1 / (T_{\text{install}} + T_{\text{ready}})$ — inverse of total time to operational state. |
| **Energy efficiency** | $\eta_{\text{energy}} = f_{\text{FPS}} / P_{\text{avg}}$ — performance per watt.                                  |
| **Deployment overhead ratio** | $R_{\text{deploy}} = T_{\text{install}} / T_{\text{ready}}$ — how long setup dominates runtime availability.      |
### 


## Results summary

Scenario S1 (FPS=10, real USB camera `/dev/video1`, ROS_DOMAIN_ID=42),
edge node = NVIDIA Jetson AGX Orin 64 GB, single measurement run per
pattern (n=1). Three of the four patterns (monolithic, microservices,
dynamic-canonical) were captured in an automated script run with **uniform methodology** —
10-minute warm-up after Ready, 3-minute rosbridge sampling window.
Overlay-canonical was captured in a separate session (2026-05-06) via
Rancher UI because its pre-install Job consistently exceeds
`helm install --wait --timeout 45m` in our CLI script (Helm aborts but
the deployment converges; details in §9 *Reproducibility caveats*).

per-pattern aggregated tables under [`metrics/`](metrics/).

### 1. Executive snapshot

| Pattern              | $T_{\text{install}}$ MEDIDO | C-7 hot-swap         | $S_{\text{img}}$ total | $T_{\text{inf}}$ (avg) | $U_{\text{GPU}}$ (avg) |
|----------------------|----------------------------:|---------------------:|-----------------------:|-----------------------:|-----------------------:|
| monolithic           |               513 s (08:33) |  n/a                 |   30.0 GB              |  38.46 ms              |                51.68 % |
| microservices        |               643 s (10:43) |  n/a                 |   41.2 GB              |  37.44 ms              |                50.77 % |
| **overlay-canonical**|               645 s (10:45) |  n/a                 |   **27.5 GB**          |  **32.70 ms**          |                51.70 % |
| **dynamic-canonical**|           **137 s (02:17)** |  **0.78 – 31.10 s**  |   30.0 GB              |  76.54 ms              |            **46.66 %** |


### 2. Image footprint and typical OTA payload

| Pattern              | $S_{\text{img}}$  total | Image breakdown                                  | OTA payload (one update)                |
|----------------------|------------------------:|--------------------------------------------------|------------------------------------------|
| monolithic           |                 30.0 GB | 1 image (whole stack)                            | 30 GB (entire image)                     |
| microservices        |                 41.2 GB | 5 images (camera, yolo, llava, voxtral, dash)    | 5–19 GB (only the changed microservice)  |
| **overlay-canonical**|             **27.5 GB** | base 2.24 + overlay-pack 25.05 + dashboard 0.25  | **25 GB** (only the overlay-pack)        |
| dynamic-canonical    |                 30.0 GB | component-host 29.77 + dashboard 0.25            | 30 GB (entire image)                     |


### 3. Cold-start ($T_{\text{install}}$)

| Pattern              |      $T_{\text{install}}$ MEDIDO | Bottleneck                                                              |
|----------------------|---------------------------------:|-------------------------------------------------------------------------|
| monolithic           |                    513 s (08:33) | single 30 GB pull (cached) + boot + LLaVA model load                    |
| microservices        |                    643 s (10:43) | 5 parallel pulls (cached) + per-pod boot + ROS 2 inter-pod negotiation  |
| **overlay-canonical**|                    949 s (15:49) | overlay-pack 26 GB pull + 17 GB extract to PVC + 17 GB HTTP sync to edge |
| **dynamic-canonical**|                **645 s (10:45)** | single 32 GB component-host pull straight to edge + bootstrap loads     |


### 4. Runtime metrics in steady state

Three patterns captured by the automated campaign 2026-05-07 with
**uniform methodology** (10 min warm-up after Ready, 3 min rosbridge
sample window). Overlay-canonical reused from the 2026-05-06 session
(see §9 for the methodology mismatch caveat).

| Metric                    | Monolithic | Microservices | Dynamic-canonical | Overlay-canonical ⁴ |
|---------------------------|-----------:|--------------:|------------------:|--------------------:|
| $T_{\text{inf}}$ (avg, ms) | 38.46     | 37.44         | 76.54             |           **32.70** |
| $f_{\text{FPS}}$ (pub)     | 9.70      | **10.11**     | 5.45              |               10.20 |
| $T_{\text{e2e}}$ (avg, ms) | 112.83    | 134.46        | 224.67            |              **15** |
| $J_{\text{inf}}$ (ms)      | 12.70     | 12.69         | 74.50             |            **8.50** |
| $U_{\text{CPU}}$ (avg, %)  | 22.51     | 24.56         | 24.24             |           **21.20** |
| $U_{\text{GPU}}$ (avg, %)  | 51.68     | 50.77         | 46.66             |               51.70 |
| $U_{\text{RAM}}$ (avg, %)  | 33.34     | 53.14         | **32.63**         |               33.30 |


### 5. Loop readiness ($T_{\text{ready}}$)

Time from container start to first ROS 2 control-loop tick:

| Pattern              | $T_{\text{ready}}$ |
|----------------------|-------------------:|
| monolithic           |   0.76 s           |
| microservices        |   0.75 s           |
| **overlay-canonical**|   **0.12 s**       |
| dynamic-canonical    |   0.18 s           |


### 6. Hot-swap latency (C-7) — the differentiator of dynamic-canonical

Time required to **swap a single ML component** without restarting the
runtime pod, end-to-end:

| Pattern              | Hot-swap one ML component                                          |
|----------------------|--------------------------------------------------------------------|
| monolithic           | ~15–25 min (rebuild image + push 30 GB + pull edge + boot)         |
| microservices        | ~5–10 min (rebuild one microservice + push 5–19 GB + pull)          |
| overlay-canonical    | ~2.5 min cold-ish (re-extract the overlay tarball)                  |
| **dynamic-canonical**| **0.78 – 31.10 s** (intra-process `LoadNode` / `UnloadNode`)        |


| Module  | Plugin                              | Load time | `unique_id` |
|---------|--------------------------------------|----------:|------------:|
| camera  | `camera_driver_pkg::CameraDriver`   |   **0.78 s** | 1 |
| yolo    | `yolo_detector_pkg::YoloDetector`   |  **20.34 s** | 2 |
| llava   | `llava_pkg::LlavaNode`              |  **31.10 s** | 3 |
| voxtral | `voxtral_pkg::VoxtralNode`          |   **4.55 s** | 4 |
| **Total (sequential)** | —                       | **56.77 s** | — |

Hot-swap on dynamic-canonical is **two to three orders of magnitude
faster** than on the other patterns.

### 7. Network latency ($L_{\text{net}}$) — cluster-level, pattern-agnostic

| Node                  | IP                | RTT avg            |
|-----------------------|-------------------|-------------------:|
| kb2 (cloud)           | 158.42.104.15     |   4.2 ms           |
| edgenode01 (Jetson)   | 158.42.104.206    |   7.9 ms           |
| worker1-kb2           | 158.42.104.103    |   30.4 ms (variable) |


### 8. When to choose which pattern

| Pattern              | Best fit                                              | Main cost                                               |
|----------------------|-------------------------------------------------------|---------------------------------------------------------|
| monolithic           | Simple system, infrequent changes                     | OTA update = whole image                                |
| microservices        | Independently evolving components                     | Heavy total image size, parallel pulls                  |
| overlay-canonical    | Multi-edge fleets with recurring AI model updates     | Cloud→PVC→edge double hop                               |
| dynamic-canonical    | A/B testing, hot-swap, iterative development          | Single fat image, no multi-edge fan-out                  |


## Repository layout

```
Models/                          Dockerfiles + ROS 2 source per workspace
  cusparselt_stub.c              Stub for 16 cuSPARSELt symbols missing in JetPack 6.1
  patch_torchvision_jetson.py    torchvision NMS patch for Jetson CUDA 12.6
  ros2_base/                     ROS 2 base + camera driver + CUDA L4T runtime
  ros2_cam_ws/                   camera_driver_pkg
  ros2_yolo_ws/                  yolo_detector_pkg (YOLOv8n)
  ros2_llava_ws/                 llava_pkg (LLaVA-1.5-7B)
  ros2_voxtral_ws/               voxtral_pkg (Voxtral-Mini-3B)
  ros2_monolithic_ws/            Monolithic image (all ROS 2 nodes baked in)
  ros2_overlay_pack/             Overlay carrier image (canonical pattern)
  ros2_component_host/           component_container_isolated host (canonical dynamic)
  ros2_dashboard/                Web UI (rosbridge + nginx)
Patterns/                        One Helm chart per deployment pattern
  monolithic/
  microservices/
  overlay-canonical/
  dynamic-canonical/
dashboard/                       Static dashboard HTML
scripts/
  benchmark/                     Measurement scripts (capture, collect, probe)
  publish_charts.sh              Manual gh-pages publish (CI does it automatically)
dist/metrics/                    Per-pattern .md and .csv summary tables
results/                         Per-run raw captures (T_ready, top, events, …)
.github/workflows/               CI/CD: lint and publish charts to gh-pages
```

## License

This repository is intended to be released under the
[MIT License](LICENSE) (an explicit `LICENSE` file should be added at
the repository root before submission).

The container images depend on third-party software and models. Verify
each downstream license matches your intended use:

- ROS 2 Humble (Apache 2.0)
- Ultralytics YOLOv8n (AGPL-3.0)
- LLaVA-1.5-7B (Llama 2 community licence)
- Voxtral-Mini-3B (Mistral AI gated access; research-only)
- HuggingFace `transformers`, `torch`, `torchvision` (Apache 2.0 / BSD)


## Maintainers

- **Miguel-Ángel Mateo Casali** — `mmateo@cigip.upv.es`
- **Francisco Fraile** — `ffraile@cigip.upv.es`
- **Andrés Boza** — `aboza@cigip.upv.es`
- CIGIP / I+D+i — Universitat Politècnica de València
