# =============================================================================
#  ros2-component-host — Canonical Dynamic Module Loading host image
#
#  Per the Dynamic Module Loading theory of the paper, this image is the
#  HOST PROCESS that loads/unloads ROS 2 components on demand via the
#  rclpy_components container_isolated. NOT a process orchestrator (which
#  was the previous non-canonical implementation) — components run IN the
#  same process as the container, sharing memory.
#
#  Image purpose: serve TWO containers in the dynamic-canonical pod:
#    1) component-host: runs `ros2 run rclpy_components component_container_isolated`
#                       Plugins discovered via setuptools entry_point
#                       'rclpy_components'.
#    2) orchestrator:   runs FastAPI app that calls the host's services
#                       (LoadNode, UnloadNode, ListNodes) on demand.
#
#  Both containers share the same image — the dynamic-canonical chart
#  defines different `command` overrides for each.
#
#  FROM ros2-base inherits:
#    • ROS 2 Humble + camera_driver (already compiled in /opt/base_ws/)
#    • CUDA L4T runtime libs
#    • numpy 1.26
#  And on top:
#    • ML stack (PyTorch + transformers + ultralytics + sounddevice + ...)
#    • The 4 refactored packages (yolo, llava, voxtral, camera) compiled
#      with their `rclpy_components` entry_points exposed.
#    • HuggingFace models baked into image (LLaVA + Voxtral)
#    • FastAPI + uvicorn for the orchestrator container
#    • rclpy_components system package (provides the container binary)
#
#  Same multi-stage cache pattern as overlay-pack — rebuilds only re-do
#  what changed downstream of the modification.
# =============================================================================
ARG REGISTRY=gitlab-cigip.alc.upv.es:5050/cigip/patrones-kubernetes
ARG ROS_DISTRO=humble

FROM ${REGISTRY}/ros2-base:latest

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=${ROS_DISTRO}

# HuggingFace cache — baked at build time (same pattern as monolithic).
ENV TRANSFORMERS_CACHE=/opt/huggingface_cache
ENV HF_HOME=/opt/huggingface_cache
ENV HF_HUB_CACHE=/opt/huggingface_cache

# ── System deps: audio + ROS components ─────────────────────────────────
# IMPORTANT: ros-humble-rclpy-components is NOT available in apt for
# Humble (only Iron+). The Python rclpy_components package must be built
# from source — see the colcon stage below.
# rclcpp_components: C++ equivalent, IS in apt (kept for completeness;
# C++ plugins would need it).
#
# ros-humble-vision-msgs: explicit pin even though ros2-base already
# installs it. The dependency surfaced when yolo_detector_pkg failed to
# load with `ModuleNotFoundError: No module named 'vision_msgs'` on a
# component-host image built against an older ros2-base. Listing it here
# makes the dependency hermetic so we don't depend on a particular
# ros2-base build state when rebuilding component-host.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      libasound2 portaudio19-dev libsndfile1 \
      ros-${ROS_DISTRO}-rclcpp-components \
      ros-${ROS_DISTRO}-composition-interfaces \
      ros-${ROS_DISTRO}-vision-msgs \
    && rm -rf /var/lib/apt/lists/* && \
    # Loud check: fail the build now if vision_msgs didn't actually install
    # (apt with --no-install-recommends sometimes silently swallows missing
    # packages on older sources).
    dpkg -s ros-${ROS_DISTRO}-vision-msgs >/dev/null 2>&1 || \
      { echo "[apt] FATAL: ros-${ROS_DISTRO}-vision-msgs not installed"; exit 1; }

# ── ML Python stack — system-wide install (NOT --target) ───────────────
# Unlike overlay-pack which uses --target so deps travel in the carrier,
# here we install system-wide because:
#   1) The image IS the runtime — no extraction step.
#   2) component_container_isolated finds plugins via the standard Python
#      site-packages mechanism (entry_points). Our refactored packages
#      need to be installed there too.
#
# transformers pinned to 4.48 — same constraint as monolithic / overlay-pack:
# LLaVA-1.5 breaks in 4.49+. Voxtral falls back to TEXT_SIMULATION mode
# (the import of VoxtralProcessor fails gracefully thanks to the try/except
# in voxtral_node.py).
RUN python3 -m pip install --no-cache-dir --upgrade pip && \
    python3 -m pip install --no-cache-dir --upgrade \
      ultralytics==8.3.2 \
      "transformers>=4.48,<4.49" \
      "accelerate>=0.34" \
      bitsandbytes \
      Pillow \
      sounddevice \
      librosa \
      soundfile \
      mistral-common \
      huggingface_hub \
      fastapi \
      uvicorn[standard] \
      pydantic

# ── Jetson PyTorch wheel (system-wide) ────────────────────────────────
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "arm64" ]; then \
      python3 -m pip install --no-cache-dir --force-reinstall --no-deps \
        "https://developer.download.nvidia.com/compute/redist/jp/v61/pytorch/torch-2.5.0a0+872d972e41.nv24.08.17622132-cp310-cp310-linux_aarch64.whl" && \
      python3 -m pip install --no-cache-dir --force-reinstall --no-deps "torchvision==0.20.0" && \
      python3 -m pip install --no-cache-dir --force-reinstall --no-deps "torchaudio==2.5.0" || true && \
      python3 /tmp/patch_torchvision_jetson.py && \
      pip uninstall -y $(pip list 2>/dev/null | grep -i 'nvidia-cu' | awk '{print $1}' | tr '\n' ' ') 2>/dev/null || true ; \
    else \
      python3 -m pip install --no-cache-dir \
        torch==2.4.1+cu121 torchvision==0.19.1+cu121 torchaudio==2.4.1+cu121 \
        --index-url https://download.pytorch.org/whl/cu121 ; \
    fi

# ── Patch transformers (synced_gpus) — system path now ─────────────────
RUN python3 - <<'PY'
import re, sys
path = '/usr/local/lib/python3.10/dist-packages/transformers/generation/utils.py'
src = open(path).read()
pattern = re.compile(
    r'^([ \t]+)synced_gpus\s*=\s*[^\n]*(?:is_fsdp_managed_module|is_deepspeed_zero3_enabled)[^\n]*$',
    re.MULTILINE,
)
new_src, n = pattern.subn(r'\1synced_gpus = False  # patched for Jetson', src)
if n == 0:
    print('[patch] FATAL: synced_gpus not found'); sys.exit(1)
open(path, 'w').write(new_src)
print(f'[patch] synced_gpus patched ({n} loc)')
PY

# ── Pre-download HF models (LLaVA public + Voxtral gated) ──────────────
RUN mkdir -p ${HF_HOME} && \
    HF_HUB_DISABLE_XET=1 python3 -c "\
from huggingface_hub import snapshot_download; \
print('[build] LLaVA...'); \
snapshot_download('llava-hf/llava-1.5-7b-hf', cache_dir='${HF_HOME}'); \
print('[build] LLaVA OK'); \
"

RUN --mount=type=secret,id=hf_token,required=true \
    HF_TOKEN="$(cat /run/secrets/hf_token)" HF_HUB_DISABLE_XET=1 python3 -c "\
import os, sys; \
from huggingface_hub import snapshot_download; \
tok = os.environ.get('HF_TOKEN', ''); \
assert len(tok) > 10, 'HF_TOKEN missing'; \
print('[build] Voxtral...'); \
snapshot_download('mistralai/Voxtral-Mini-3B-2507', cache_dir='${HF_HOME}', token=tok); \
print('[build] Voxtral OK'); \
" && \
    SIZE_KB=$(du -sk ${HF_HOME}/models--mistralai--Voxtral-Mini-3B-2507/ 2>/dev/null | awk '{print $1}') && \
    [ "$SIZE_KB" -gt 1000000 ] || { echo "[build] FATAL: Voxtral cache <1GB"; exit 1; }

# Make HF cache fully offline at runtime — no accidental Hub calls.
ENV HF_HUB_OFFLINE=1
ENV TRANSFORMERS_OFFLINE=1

# ── Build the 4 refactored ROS 2 packages ──────────────────────────────
# colcon installs them (without --symlink-install, real files) so their
# rclpy_components entry_points are discoverable by the container_isolated.
#
# rclpy_components is fetched from ros2/rclpy (humble branch) and built
# alongside our packages. In Humble there is no apt deb for it; the
# subdirectory rclpy_components/ in the rclpy repo IS a colcon package
# (has package.xml + setup.py) and that's the supported install path.
WORKDIR /opt/component_ws
# rclpy_components is provided as a LOCAL VENDORED package (shim) because:
#   • ros-humble-rclpy-components doesn't exist in apt for Humble (only Iron+).
#   • The iron/jazzy branches of ros2/rclpy don't include the
#     `rclpy_components` subdirectory in the layout we expected.
# Our shim implements the same component_container_isolated executable
# and the LoadNode/UnloadNode/ListNodes services. ~250 lines of Python
# in Models/ros2_component_host/rclpy_components_shim/.
COPY Models/ros2_component_host/rclpy_components_shim src/rclpy_components

COPY Models/ros2_yolo_ws/src/yolo_detector_pkg     src/yolo_detector_pkg
COPY Models/ros2_llava_ws/src/llava_pkg            src/llava_pkg
COPY Models/ros2_voxtral_ws/src/voxtral_pkg        src/voxtral_pkg

SHELL ["/bin/bash", "-lc"]
RUN source /opt/ros/${ROS_DISTRO}/setup.bash && \
    source /opt/base_ws/install/setup.bash && \
    colcon build \
      --packages-select rclpy_components yolo_detector_pkg llava_pkg voxtral_pkg

# Fail loudly at build time if rclpy_components didn't compile correctly
RUN source /opt/ros/${ROS_DISTRO}/setup.bash && \
    source /opt/base_ws/install/setup.bash && \
    source /opt/component_ws/install/setup.bash && \
    ros2 pkg list | grep -q '^rclpy_components$' || { \
      echo "[build] FATAL: rclpy_components not registered with ament_index"; \
      exit 1; \
    } && \
    ros2 pkg executables rclpy_components | grep -q 'component_container_isolated' || { \
      echo "[build] FATAL: component_container_isolated executable not found"; \
      exit 1; \
    } && \
    echo "[build] rclpy_components verified."

# ── YOLOv8 weights ─────────────────────────────────────────────────────
RUN mkdir -p /opt/models && \
    python3 -c "\
import urllib.request; \
url='https://github.com/ultralytics/assets/releases/download/v8.3.0/yolov8n.pt'; \
urllib.request.urlretrieve(url, '/opt/models/yolov8n.pt'); \
print('YOLOv8n cached'); \
"

# ── Orchestrator FastAPI app ───────────────────────────────────────────
COPY Models/ros2_component_host/orchestrator /opt/orchestrator

# ── Setup the env so both containers (component-host and orchestrator)
#    can `source` the workspaces from a fresh shell.
RUN echo "source /opt/ros/${ROS_DISTRO}/setup.bash" >> /etc/bash.bashrc && \
    echo "source /opt/base_ws/install/setup.bash" >> /etc/bash.bashrc && \
    echo "source /opt/component_ws/install/setup.bash" >> /etc/bash.bashrc

# Default CMD is component_container_isolated. The Helm chart overrides
# this for the orchestrator container (which runs uvicorn instead).
CMD ["bash", "-lc", "ros2 run rclpy_components component_container_isolated"]
