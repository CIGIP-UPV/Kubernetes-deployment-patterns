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
├── Models/                          # source code of the five container images
│   ├── ros2_cam_ws/                 #   camera driver
│   ├── ros2_yolo_ws/                #   YOLOv8-nano detector (GPU)
│   ├── ros2_llava_ws/               #   LLaVA-1.5-7B vision–language (GPU)
│   ├── ros2_voxtral_ws/             #   Voxtral-Mini-3B voice interaction
│   ├── ros2_monolithic_ws/          #   monolithic carrier (4 nodes in one image)
│   ├── ros2_overlay_pack/           #   overlay-canonical carrier (deps + models)
│   ├── ros2_component_host/         #   dynamic-loader host (component_container)
│   ├── ros2_base/                   #   minimal ROS 2 + CUDA L4T base image
│   ├── ros2_dashboard/              #   web control panel (rosbridge + nginx)
│   ├── cusparselt_stub.c            #   stub for libcusparseLt.so.0 on Jetson
│   └── patch_torchvision_jetson.py  #   torchvision NMS / Triton patches
│
├── Patterns/                        # the four Helm charts (chart versions 1.0.0)
│   ├── monolithic/
│   ├── microservices/
│   ├── dynamic-canonical/
│   └── overlay-canonical/
│
├── scripts/benchmark/               # automated measurement campaign
│   ├── run_n_campaigns.sh           #   wrapper: N warm + M cold-cold replicas
│   ├── run_full_campaign.sh         #     core campaign (4 patterns in series)
│   ├── sample_dashboard_metrics.py  #     rosbridge sampler (runtime metrics)
│   ├── llava_trigger_driver.py      #     deterministic /llava/trigger publisher
│   ├── fix_comparison_csv.sh        #     post-hoc cleaner of comparison.csv
│   ├── aggregate_meta_campaign.sh   #     mean/stdev/min/max per pattern × regime
│   └── measure_overlay_incremental_warm.sh
│
├── paper/                           # ready-to-paste LaTeX artifacts
│   ├── results_tables.tex           #   final tables of Section IV
│   ├── IV_B_overlay_paragraph.tex   #   the overlay-incremental paragraph
│   ├── related_work.tex             #   Section II as published
│   └── article_revision.docx        #   Section III+ in tracked-changes form
│
├── dist/metrics/                    # aggregated measurement data (CSV)
│   ├── meta_campaign_<TS>.csv               # raw, one row per cycle × pattern
│   └── meta_campaign_<TS>_summary.csv       # mean ± std per pattern × regime
│
├── results/                         # raw measurement data
│   ├── _campaigns/<TS>/             #   one directory per cycle of the campaign
│   │   └── <pattern>/               #     per-pattern artifacts of that cycle
│   └── overlay_incremental_warm/<TS>/measurements.csv
│
├── dashboard/                       # standalone HTML dashboard (rosbridge UI)
├── docs/                            # supplementary documentation
│   ├── REPRODUCIBILITY.md           #   exact commands to replicate the campaign
│   └── JETSON_NOTES.md              #   non-obvious Jetson + K3s issues we hit
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

Section III of the article describes each pattern in detail and
Section IV reports the empirical comparison.

## How to reproduce the campaign

See [`docs/REPRODUCIBILITY.md`](docs/REPRODUCIBILITY.md) for the exact
commands. In short:

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

7. (Optional) Reproduce the overlay-canonical *incremental warm*
   measurement that requires the chart's design-intent configuration:

   ```bash
   helm upgrade --install overlay-pattern \
     Patterns/overlay-canonical/helm/ros2-overlay-canonical/ -n ros2exp \
     --set overlay.layered=true --set overlay.pipeline=true \
     --set overlayMount.kind=hostPath
   kubectl wait --for=condition=Ready pod/overlay-pattern-0 -n ros2exp \
     --timeout=30m

   N=5 PAUSE_BETWEEN=60 \
     bash scripts/benchmark/measure_overlay_incremental_warm.sh
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

The benchmark workload corresponds to the use case described in
Section III.A of the article: automated inspection and classification
of post-consumer textile garments in a circular-economy workflow.
Three AI capabilities run concurrently:

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
Andrés Boza ([ORCID](https://orcid.org/0000-0002-5429-0416)),
Francisco Fraile ([ORCID](https://orcid.org/0000-0003-0852-8953))
— Centro de Investigación en Gestión e Ingeniería de Producción
(CIGIP), Universitat Politècnica de València, Spain.

Corresponding author: **mmateo@cigip.upv.es**.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
