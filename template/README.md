# Bring Your Own Model Template

Evaluate **your own AI model** under the four ROS 2 deployment patterns of this
repository (monolithic, microservices, dynamic module loading, overlay
workspaces) without modifying any Helm chart, and reusing the full measurement
methodology of the paper (deployment regimes, runtime metrics, confidence
intervals, queue and drop instrumentation).

## How it works: the perception slot

All four patterns in this repository start their perception node with the same
launch line, baked into the chart templates:

```
ros2 run yolo_detector_pkg yolo_detector
```

and the dynamic pattern loads it through the plugin entry point
`yolo_detector_pkg::YoloDetector`.

This template provides a package that **intentionally reuses those names**
(`template/yolo_detector_pkg/`). By building your model into a package with
the slot name, every chart starts it unmodified. Your model does **not** need
to be an object detector; the slot name is inherited infrastructure naming.
You only edit one file, and the same code is then packaged four ways, which is
precisely the comparison the paper makes.

![Runtime topology per pattern](../docs/figures/runtime_topology.png)

```
template/
├── README.md                  this file
├── yolo_detector_pkg/         THE ONLY CODE YOU EDIT (your model node)
├── monolithic/                Dockerfile + deploy script
├── microservices/             Dockerfile + deploy script
├── dynamic-loader/            Dockerfile + deploy script + load/unload example
└── overlay-workspaces/        Dockerfile (carrier rebuild) + deploy script
```

## Step 1: implement your model

Edit `yolo_detector_pkg/yolo_detector_pkg/object_detection.py`. The node is
fully functional out of the box with a **synthetic model** (it consumes real
camera frames and publishes simulated results with realistic timing), so you
can validate the whole pipeline on the four patterns before writing a single
line of inference code. Then replace two methods:

- `load_model(self)`: load your weights (called once at startup).
- `infer(self, cv_image) -> dict`: run inference on one frame and return a
  JSON serialisable dict.

The node already publishes the standard benchmark topics of this repository
(`/benchmark/latency_ms`, `/benchmark/inference_ms`,
`/benchmark/frames_received`, `/benchmark/queue_wait_ms`), so the dashboard,
`scripts/benchmark/run_full_campaign.sh`, the cold start regimes and
`scripts/benchmark/aggregate_with_ci.py` work on your model with no changes.

Add your Python dependencies to `template/<pattern>/Dockerfile` where marked
(`# YOUR DEPS HERE`).

## Step 2: pick a pattern, build and deploy

Each pattern folder has a `Dockerfile` and a `deploy.sh`. All of them expect
two environment variables:

```
export REG=<your registry>/<your project>     # e.g. registry.example.com/robots
export TAG=mymodel-v1
```

| Pattern | What the build does | Deploy |
|---|---|---|
| `monolithic/` | Extends the monolithic image; your package overlays the perception slot | `bash monolithic/deploy.sh` |
| `microservices/` | Extends only the perception service image; the other services stay stock | `bash microservices/deploy.sh` |
| `dynamic-loader/` | Extends the component host; your plugin becomes hot swappable | `bash dynamic-loader/deploy.sh` |
| `overlay-workspaces/` | Rebuilds the carrier with your package inside the overlay layer | `bash overlay-workspaces/deploy.sh` |

Each `deploy.sh` builds the image, pushes it, and installs the corresponding
chart with the image override (`--set ...`), leaving everything else stock.
See the README inside each folder for the pattern specific details and
caveats.

Prerequisites: a K3s or Kubernetes cluster with the base images of this
repository available in a registry (see the root README to build them), a node
with the camera (or set `synthetic_mode:=true` on the camera driver), and the
`regcred` pull secret in the `ros2exp` namespace.

## Step 3: measure your model like the paper does

```
PATTERNS="monolithic" COLD_MODE=warm bash scripts/benchmark/run_full_campaign.sh
```

Or the full matrix with the three deployment regimes:

```
N_WARM=5 N_IMAGECOLD=3 N_PRISTINE=3 bash scripts/benchmark/run_coldstart_matrix.sh
```

Aggregate with confidence intervals:

```
python3 scripts/benchmark/aggregate_with_ci.py
```

## Advanced: keeping your own package name

If you prefer your own package identity instead of the slot name, you must
touch three places, because the launch commands are baked into the chart
templates: (a) the `command` blocks of the pattern statefulsets under
`Patterns/*/helm/*/templates/`, (b) for the dynamic pattern, one entry in
`MODULE_REGISTRY` of `Models/ros2_component_host/orchestrator/orchestrator.py`
(the dynamic Dockerfile in this template shows how to inject it at build
time), and (c) your package `setup.py` entry points. The slot approach needs
none of this.

## Validation status

The template is derived from the exact mechanisms used by the four evaluated
patterns (chart launch commands, entry point discovery, benchmark topics). The
synthetic node compiles and follows the same interface as the evaluated
perception package. Run the smoke deploy of one pattern before launching long
campaigns.
