# Analysis of Distributed AI Model Architectures for Cloud–Edge Robotic Systems Utilizing ROS 2

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Reproducibility artifact for the article *"Analysis of Distributed AI
Model Architectures for Cloud–Edge Robotic Systems Utilizing ROS 2"*
submitted to **IEEE Access** (2026). This repository contains the
complete source code, Helm charts, benchmark scripts and measurement
data of the comparative evaluation of four ROS 2 deployment patterns —
*monolithic containers*, *microservices*, *dynamic module loading* and
*overlay workspaces* — running a multimodal AI workload (YOLOv8-nano +
LLaVA-1.5-7B + Voxtral-Mini-3B) on a K3s cluster pairing an NVIDIA
Jetson AGX Orin edge node with two amd64 cloud nodes.

> If you use this artifact please cite both the article and this
> repository (see [CITATION.cff](CITATION.cff)).

## Repository layout

```
.
├── Models/                          # source code of the container images
│   ├── ros2_base/                   #   minimal ROS 2 + CUDA L4T base image
│   ├── ros2_cam_ws/                 #   camera driver
│   ├── ros2_yolo_ws/                #   YOLOv8-nano detector (GPU)
│   ├── ros2_llava_ws/               #   LLaVA-1.5-7B vision–language (GPU)
│   ├── ros2_voxtral_ws/             #   Voxtral-Mini-3B voice interaction
│   ├── ros2_monolithic_ws/          #   monolithic carrier (4 nodes in one image)
│   ├── ros2_overlay_pack/           #   overlay-canonical carrier (deps + models)
│   ├── ros2_component_host/         #   dynamic-loader host (component_container)
│   ├── ros2_dashboard/              #   web control panel (rosbridge + nginx)
│   ├── cusparselt_stub.c            #   stub for libcusparseLt.so.0 on Jetson
│   └── patch_torchvision_jetson.py  #   torchvision NMS / Triton patches
│
├── Patterns/                        # the four Helm charts (chart version 1.0.0)
│   ├── monolithic/
│   ├── microservices/
│   ├── dynamic-canonical/
│   └── overlay-canonical/
│
├── scripts/
│   ├── benchmark/                   # automated measurement campaign
│   │   ├── run_n_campaigns.sh             # wrapper: N warm + M cold-cold replicas
│   │   ├── run_full_campaign.sh           #   core campaign (4 patterns in series)
│   │   ├── capture_pattern_run.sh         #     per-pattern install + sample driver
│   │   ├── sample_dashboard_metrics.py    #     rosbridge sampler (runtime metrics)
│   │   ├── llava_trigger_driver.py        #     deterministic /llava/trigger publisher
│   │   ├── trigger_test.py                #     quick-check of the trigger pipeline
│   │   ├── ros_latency_probe.py           #     end-to-end latency probe
│   │   ├── collect_metrics.sh             #     post-cycle metric collector
│   │   ├── fix_comparison_csv.sh          #     post-hoc cleaner of comparison.csv
│   │   ├── aggregate_meta_campaign.sh     #     mean ± std per pattern × regime
│   │   ├── capture_dynamic_load_unload.sh #     per-module hot-swap timing
│   │   ├── measure_overlay_once.sh        #     single overlay install (manual)
│   │   └── measure_overlay_incremental_warm.sh
│   ├── prepare_release.sh           # Zenodo / GitHub release cleanup (dry-run by default)
│   └── publish_charts.sh            # push the four Helm charts to the OCI registry
│
├── results/                         # raw measurement data per cycle
│   ├── _campaigns/                            #   raw rosbridge samples per cycle
│   │   └── <TS>/<pattern>/                    #     one folder per cycle × pattern
│   ├── overlay_incremental_warm/
│   │   └── 20260527-122308/measurements.csv   # 5-cycle rollout-restart, 73.6 ± 0.5 s
│   └── dynamic-canonical/load-unload/
│       └── load_unload_per_module.csv         # per-module hot-swap latencies (Table 5)
│
├── dashboard/                       # standalone HTML dashboard (rosbridge UI)
│   └── index.html
│
├── README.md                        # this file
├── LICENSE                          # Apache 2.0
└── CITATION.cff                     # citation metadata for Zenodo / GitHub
```

## The four deployment patterns at a glance

| Pattern                | What it is                                                                                  | Image footprint | OTA payload   |
|------------------------|---------------------------------------------------------------------------------------------|-----------------|---------------|
| **Monolithic**         | Single 30 GB image bundling ROS 2 runtime, all four AI nodes and Python deps.               | 30.01 GB        | 30 GB         |
| **Microservices**      | Five separate images, one pod per service, communicate via CycloneDDS.                      | 47.25 GB        | 5–19 GB       |
| **Dynamic loading**    | One `component_container_isolated` host that loads the four nodes as plugins on demand.     | 30.02 GB        | 30 GB         |
| **Overlay workspaces** | Immutable 2.24 GB base + 25 GB mutable carrier extracted on edge from a cloud-side server.  | 27.54 GB        | 25 GB         |

## How to reproduce the campaign

1. Provision a K3s cluster matching the topology in Table 1 (one Jetson
   AGX Orin edge node, two amd64 cloud nodes).
2. Set up SSH and passwordless `sudo k3s` between the control-plane
   node and the three cluster nodes (needed for the cold-cold image
   purge between cycles).
3. Build and push the five container images
   (`Models/ros2_*_ws/docker/Dockerfile`) to your own registry. The
   build uses BuildKit and requires an `HF_TOKEN` secret with access to
   the Voxtral-Mini-3B-2507 gated repository.
4. Create the `ros2exp` namespace and the `regcred` image pull secret.
5. Run the multi-replicate campaign:

   ```bash
   PATTERNS="monolithic microservices overlay-canonical dynamic-canonical" \
     N_WARM=5 N_COLD=3 \
     nohup bash scripts/benchmark/run_n_campaigns.sh > mega.log 2>&1 &
   ```

   Approximate wall-clock time: 14 hours.
6. Aggregate the data:

   ```bash
   SUM=$(ls -1t results/_campaigns/_summary_*.csv | head -1)
   for d in $(awk -F',' 'NR>1 {print $3}' "$SUM"); do
     bash scripts/benchmark/fix_comparison_csv.sh "$d"
   done
   bash scripts/benchmark/aggregate_meta_campaign.sh "$SUM"
   ```


## Pre-built images

For reviewers who do not want to rebuild from scratch, the same five
images used in the published measurements are mirrored in the
institutional GitLab registry of CIGIP-UPV
(`gitlab-cigip.alc.upv.es:5050/cigip/patrones-kubernetes/`). They can
be made available upon reasonable request to the corresponding author.
The Dockerfiles in this repository are sufficient to rebuild
byte-for-byte equivalent images on any host with NVIDIA Container
Toolkit support.

## Workload

- **YOLOv8-nano** for real-time garment detection.
- **LLaVA-1.5-7B** in FP16 for vision–language reasoning, triggered
  every 30 s during the warm-up and sampling windows via a
  deterministic external publisher (see
  `scripts/benchmark/llava_trigger_driver.py`).
- **Voxtral-Mini-3B** for voice interaction (Phase 1 in this paper:
  loaded in memory, not actively driving an audio device).

The four deployment patterns receive identical workloads and identical
ROS 2 application code; they differ only in how the four nodes are
packaged and started.

## Citing

Please cite both the article and this repository. The repository's
`CITATION.cff` is set up so that GitHub and Zenodo render the citation
metadata automatically; the Zenodo DOI generated upon archival is the
preferred citation key for the dataset.

## Authors

Miguel Ángel Mateo-Casalí ([ORCID](https://orcid.org/0000-0001-5086-9378)),
Daniel González El Yachouti ([ORCID](https://orcid.org/0009-0005-5163-0509)),
Francisco Fraile ([ORCID](https://orcid.org/0000-0003-0852-8953)),
Andrés Boza ([ORCID](https://orcid.org/0000-0002-5429-0416))
— Centro de Investigación en Gestión e Ingeniería de Producción
(CIGIP), Universitat Politècnica de València, Spain.

Corresponding author: **mmateo@cigip.upv.es**.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
