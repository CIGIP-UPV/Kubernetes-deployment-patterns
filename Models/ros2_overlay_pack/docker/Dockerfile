# =============================================================================
#  ros2-overlay-pack — OCI carrier image for the canonical Overlay Pattern
#
#  Per the Overlay Workspaces theory of the paper, this image contains the
#  MUTABLE overlay layer: AI nodes + ML runtime + model weights. It is the
#  artifact that gets "delivered via OTA Updates" to the robot.
#
#  IMPORTANT: this image is NOT designed to run as a service. Its only
#  purpose is to be pulled by a Helm pre-install Job, which copies
#  /opt/overlay to a PVC on the cloud node (kb2). The runtime pod on
#  edgenode01 consumes the overlay via emptyDir mount, NOT this image.
#
#  Multi-stage:
#    • builder: FROM ros2-base — installs ML stack to /opt/overlay/python-deps,
#      downloads HF models, compiles overlay_ws to /opt/overlay/install
#    • carrier: FROM busybox — contains ONLY the /opt/overlay/ artifacts
#
#  Layout of /opt/overlay/ in the final carrier:
#    /opt/overlay/install/             ← compiled colcon overlay workspace
#    /opt/overlay/python-deps/         ← PyTorch + transformers + ... (pip --target)
#    /opt/overlay/huggingface_cache/   ← LLaVA + Voxtral model weights
#    /opt/overlay/models/yolov8n.pt    ← YOLOv8 weights
#
#  At runtime (StatefulSet of overlay-canonical):
#    export PYTHONPATH=/opt/overlay/python-deps:${PYTHONPATH}
#    source /opt/ros/humble/setup.bash
#    source /opt/base_ws/install/setup.bash
#    source /opt/overlay/install/setup.bash
#    ros2 run yolo_detector_pkg yolo_detector & ...
# =============================================================================
ARG REGISTRY=gitlab-cigip.alc.upv.es:5050/cigip/patrones-kubernetes
ARG ROS_DISTRO=humble

# ── STAGE 1: BUILDER (FROM ros2-base, FORCED ARM64) ──────────────────────────
# We force the builder to arm64 because:
#   1) ros2-base is arm64-only (Jetson L4T runtime).
#   2) The CARRIER's job is to TRANSPORT the overlay artifacts as opaque
#      bytes, not to execute them. The /opt/overlay/ contents are arm64
#      (Jetson PyTorch wheel, etc.), but they travel inside a tarball
#      that is later extracted on the edge node (also arm64).
#   3) The CARRIER itself, however, runs on the cloud node which may be
#      amd64. So the FINAL stage uses busybox (multi-arch) — see below.
# Build with: --platform=linux/amd64,linux/arm64 to publish a multi-arch
# manifest of the carrier. Containerd on each node selects the right one.
FROM --platform=linux/arm64 ${REGISTRY}/ros2-base:latest AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=${ROS_DISTRO}

# Path conventions used throughout this Dockerfile and the runtime StatefulSet.
# These match what is mounted at /opt/overlay/... in the runtime pod.
ENV OVERLAY_ROOT=/opt/overlay
ENV OVERLAY_PYDEPS=/opt/overlay/python-deps
ENV HF_HOME=/opt/overlay/huggingface_cache
ENV TRANSFORMERS_CACHE=/opt/overlay/huggingface_cache
ENV HF_HUB_CACHE=/opt/overlay/huggingface_cache

# ── Audio system deps (Voxtral mic + librosa loading) ──────────────────────
# These are SYSTEM-level (.so files in /usr/lib/...) — they cannot be
# packaged into /opt/overlay/python-deps. The runtime image (ros2-base)
# does NOT have them. To make the overlay self-contained we copy the
# specific .so files into /opt/overlay/system-libs/ at the end of this
# build, and the runtime sets LD_LIBRARY_PATH accordingly.
RUN for attempt in 1 2 3; do \
      echo "[apt] Attempt $attempt..." && \
      apt-get update && \
      apt-get install -y --no-install-recommends \
        libasound2 portaudio19-dev libsndfile1 \
      && break \
      || { echo "[apt] Attempt $attempt failed (QEMU?), retrying..."; sleep 2; }; \
    done && rm -rf /var/lib/apt/lists/*

# ── ML Python stack — installed to /opt/overlay/python-deps (NOT system-wide)
# Why --target: dist-packages of the BUILDER stage is thrown away. We need
# the ML libs to live UNDER /opt/overlay/ so the carrier image transports
# them and the runtime pod picks them up via PYTHONPATH.
#
# transformers pinned to 4.48 to match the monolithic image's choice (LLaVA-1.5
# breaks in 4.49+ due to @check_model_inputs decorator). Implication: Voxtral
# falls back to TEXT_SIMULATION mode in this image because VoxtralProcessor
# was introduced in 4.54+. See PLAN section 10 (notes on deviations).
#
# numpy is NOT installed here — it's already in the base image (1.26),
# pinned to be compatible with the Jetson PyTorch wheel below.
RUN python3 -m pip install --no-cache-dir --upgrade pip && \
    python3 -m pip install --no-cache-dir --target ${OVERLAY_PYDEPS} \
      ultralytics==8.3.2 \
      "transformers>=4.48,<4.49" \
      "accelerate>=0.34" \
      bitsandbytes \
      Pillow \
      sounddevice \
      librosa \
      soundfile \
      mistral-common \
      huggingface_hub

# ── Jetson PyTorch wheel (after deps so pip doesn't downgrade it) ───────────
# The wheel itself is force-reinstall'd with --no-deps to override any
# transitive PyTorch that pip resolved during the previous step.
# Same wheel as ros2-monolithic, ros2-llava, ros2-voxtral.
# patch_torchvision_jetson.py is staged in /tmp/ by ros2-base.
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "arm64" ]; then \
      python3 -m pip install --no-cache-dir --target ${OVERLAY_PYDEPS} \
        --force-reinstall --no-deps \
        "https://developer.download.nvidia.com/compute/redist/jp/v61/pytorch/torch-2.5.0a0+872d972e41.nv24.08.17622132-cp310-cp310-linux_aarch64.whl" && \
      python3 -m pip install --no-cache-dir --target ${OVERLAY_PYDEPS} \
        --force-reinstall --no-deps "torchvision==0.20.0" && \
      python3 -m pip install --no-cache-dir --target ${OVERLAY_PYDEPS} \
        --force-reinstall --no-deps "torchaudio==2.5.0" || true && \
      PYTHONPATH=${OVERLAY_PYDEPS} python3 /tmp/patch_torchvision_jetson.py ; \
    else \
      python3 -m pip install --no-cache-dir --target ${OVERLAY_PYDEPS} \
        torch==2.4.1+cu121 torchvision==0.19.1+cu121 torchaudio==2.4.1+cu121 \
        --index-url https://download.pytorch.org/whl/cu121 ; \
    fi

# ── Patch transformers for Jetson compatibility ─────────────────────────────
# Same sed patch as monolithic/llava/voxtral, but operating on the --target
# install path (NOT the system dist-packages, which is empty for transformers).
# Removes the FSDP/DeepSpeed check that crashes Jetson PyTorch (no
# torch.distributed available).
RUN python3 - <<'PY'
import os, re, sys
overlay_pydeps = os.environ['OVERLAY_PYDEPS']
path = f'{overlay_pydeps}/transformers/generation/utils.py'
src = open(path).read()
pattern = re.compile(
    r'^([ \t]+)synced_gpus\s*=\s*[^\n]*(?:is_fsdp_managed_module|is_deepspeed_zero3_enabled)[^\n]*$',
    re.MULTILINE,
)
new_src, n = pattern.subn(
    r'\1synced_gpus = False  # patched for Jetson (no torch.distributed)',
    src
)
if n == 0:
    print('[patch] ERROR: could not find synced_gpus assignment in transformers.')
    print('[patch] Dumping context:')
    for i, line in enumerate(src.splitlines(), 1):
        if 'synced_gpus' in line:
            print(f'  {i}: {line}')
    sys.exit(1)
open(path, 'w').write(new_src)
print(f'[patch] synced_gpus patched in {n} location(s) at {path}')
PY

# ── Pre-download LLaVA model (public, no token needed) ─────────────────────
RUN mkdir -p ${HF_HOME} && \
    PYTHONPATH=${OVERLAY_PYDEPS} HF_HUB_DISABLE_XET=1 python3 -c "\
from huggingface_hub import snapshot_download; \
print('[build] Downloading LLaVA-1.5-7b-hf...'); \
snapshot_download('llava-hf/llava-1.5-7b-hf', cache_dir='${HF_HOME}'); \
print('[build] LLaVA cached.'); \
" && \
    SIZE_KB=$(du -sk ${HF_HOME}/models--llava-hf--llava-1.5-7b-hf/ 2>/dev/null | awk '{print $1}') && \
    echo "[build] LLaVA cache size: ${SIZE_KB} KB" && \
    if [ -z "$SIZE_KB" ] || [ "$SIZE_KB" -lt 1000000 ]; then \
      echo "[build] FATAL: LLaVA cache size too small (${SIZE_KB} KB < 1 GB)" ; \
      ls -laR ${HF_HOME}/ ; \
      exit 1 ; \
    fi

# ── Pre-download Voxtral model (gated, requires HF_TOKEN secret) ────────────
# Build with:
#   DOCKER_BUILDKIT=1 docker buildx build \
#     --secret id=hf_token,env=HF_TOKEN \
#     --build-arg TORCH_VARIANT=auto --platform linux/arm64 \
#     -t $REG/ros2-overlay-pack:latest \
#     -f Models/ros2_overlay_pack/docker/Dockerfile \
#     --provenance=false --push .
#
# The fail-fast at the end ensures a token misconfiguration is caught at
# build time, not at runtime when the pod tries to load the model.
RUN --mount=type=secret,id=hf_token,required=true \
    PYTHONPATH=${OVERLAY_PYDEPS} HF_TOKEN="$(cat /run/secrets/hf_token)" \
    HF_HUB_DISABLE_XET=1 python3 -c "\
import os, sys; \
from huggingface_hub import snapshot_download; \
tok = os.environ.get('HF_TOKEN', ''); \
print(f'[build] HF_TOKEN length: {len(tok)} (must be > 0)'); \
assert len(tok) > 10, '[build] FATAL: HF_TOKEN empty or too short'; \
print('[build] Downloading Voxtral-Mini-3B-2507 (gated)...'); \
snapshot_download('mistralai/Voxtral-Mini-3B-2507', cache_dir='${HF_HOME}', token=tok); \
print('[build] Voxtral cached.'); \
" && \
    SIZE_KB=$(du -sk ${HF_HOME}/models--mistralai--Voxtral-Mini-3B-2507/ 2>/dev/null | awk '{print $1}') && \
    echo "[build] Voxtral cache size: ${SIZE_KB} KB" && \
    if [ -z "$SIZE_KB" ] || [ "$SIZE_KB" -lt 1000000 ]; then \
      echo "[build] FATAL: Voxtral cache size too small (${SIZE_KB} KB < 1 GB)" ; \
      ls -laR ${HF_HOME}/ ; \
      exit 1 ; \
    fi

# ── Compile overlay ROS 2 workspace ─────────────────────────────────────────
# colcon builds yolo_detector_pkg + llava_pkg + voxtral_pkg over the base_ws
# (which already has camera_driver_pkg). --install-base puts the result at
# /opt/overlay/install/ so it ends up in the carrier.
WORKDIR /opt/overlay_build
COPY Models/ros2_yolo_ws/src/yolo_detector_pkg     src/yolo_detector_pkg
COPY Models/ros2_llava_ws/src/llava_pkg            src/llava_pkg
COPY Models/ros2_voxtral_ws/src/voxtral_pkg        src/voxtral_pkg

SHELL ["/bin/bash", "-lc"]
# IMPORTANT: NO --symlink-install here.
#
# With --symlink-install, colcon-python uses pip install editable mode and
# creates .egg-link files in install/.../site-packages/ that point back to
# /opt/overlay_build/src/. Those source paths exist in the BUILDER stage but
# NOT in the FROM busybox carrier stage (we only COPY /opt/overlay/, not
# /opt/overlay_build/). The egg-links would be dangling references and the
# runtime pod's `source setup.bash` would fail to import the packages.
#
# Without --symlink-install, colcon copies the .py files into install/
# directly, making the install/ tree self-contained and portable. The
# carrier transports actual files, not links.
#
# Trade-off: rebuilds in dev iteration are slightly slower (full file copy
# vs symlink). For a CI/release build like this one, that's irrelevant.
RUN source /opt/ros/${ROS_DISTRO}/setup.bash && \
    source /opt/base_ws/install/setup.bash && \
    colcon build \
      --install-base ${OVERLAY_ROOT}/install \
      --build-base /opt/overlay_build/build \
      --packages-select yolo_detector_pkg llava_pkg voxtral_pkg

# ── YOLOv8 weights (downloaded at build, baked into overlay) ────────────────
# Public download from ultralytics GitHub releases. ~6 MB. No HF token needed.
RUN mkdir -p ${OVERLAY_ROOT}/models && \
    python3 -c "\
import urllib.request, os; \
url='https://github.com/ultralytics/assets/releases/download/v8.3.0/yolov8n.pt'; \
dst='${OVERLAY_ROOT}/models/yolov8n.pt'; \
print('[build] Downloading YOLOv8n weights...'); \
urllib.request.urlretrieve(url, dst); \
print(f'[build] Saved {os.path.getsize(dst)/1e6:.1f} MB to {dst}'); \
"

# ── Stage system .so files needed by ML deps ────────────────────────────────
# libasound, libportaudio, libsndfile etc. live in /usr/lib/aarch64-linux-gnu/
# at build time. The runtime image (ros2-base) does NOT have them, so we copy
# them into /opt/overlay/system-libs/ and the runtime sets LD_LIBRARY_PATH.
# We follow symlinks (-L) to copy actual .so files.
RUN mkdir -p ${OVERLAY_ROOT}/system-libs && \
    for lib in libasound libportaudio libsndfile libFLAC libogg libvorbis libopus libmp3lame; do \
      find /usr/lib /lib -name "${lib}*.so*" 2>/dev/null | \
        xargs -I{} cp -aL {} ${OVERLAY_ROOT}/system-libs/ 2>/dev/null || true; \
    done && \
    echo "[build] Staged system .so files:" && \
    ls ${OVERLAY_ROOT}/system-libs/ | head -30

# ── Final size check before carrier stage ───────────────────────────────────
RUN echo "[build] Overlay artifact summary:" && \
    du -sh ${OVERLAY_ROOT}/install/        2>/dev/null && \
    du -sh ${OVERLAY_ROOT}/python-deps/    2>/dev/null && \
    du -sh ${OVERLAY_ROOT}/huggingface_cache/ 2>/dev/null && \
    du -sh ${OVERLAY_ROOT}/models/         2>/dev/null && \
    du -sh ${OVERLAY_ROOT}/system-libs/    2>/dev/null && \
    echo "[build] TOTAL:" && du -sh ${OVERLAY_ROOT}

# ── STAGE 2: CARRIER (FROM busybox) ─────────────────────────────────────────
# busybox:1.36 has /bin/sh + cp + ls + everything the Helm Job initContainer
# needs to extract /opt/overlay to the PVC. ~2 MB image, ~17 GB total with
# the overlay artifacts.
#
# This image is NEVER run as a service. Helm Job command is something like:
#   ["sh", "-c", "cp -av /opt/overlay/. /pvc/overlay/$VERSION/"]
FROM busybox:1.36

LABEL purpose="OCI carrier — overlay artifacts for ROS 2 canonical Overlay pattern"
LABEL not-runnable-as-service="true"

COPY --from=builder /opt/overlay /opt/overlay

# Default command is a no-op so accidentally running this image doesn't loop.
# The Helm Job overrides this with the actual cp command.
CMD ["sh", "-c", "echo 'ros2-overlay-pack is a carrier image, not a service. Use as initContainer with cp command.' && ls -la /opt/overlay"]
