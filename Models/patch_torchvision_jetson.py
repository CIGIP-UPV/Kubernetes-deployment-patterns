#!/usr/bin/env python3
"""
Patch torchvision for NVIDIA Jetson compatibility.

Problem: PyPI torchvision binary is compiled against CUDA 13 (libcudart.so.13),
but Jetson JetPack 6.1 has CUDA 12.6. The C extension (_C.so) cannot load,
which breaks operator registration and NMS.

Patches applied:
  1. _meta_registrations.py → no-op (only needed for torch.compile)
  2. ops/boxes.py → nms() gets a pure-PyTorch fallback when C extension fails
  3. ops/roi_align.py → replace torch._dynamo import with inline stub
     (torch.compile/Triton not supported on aarch64; the import cascades into
      torch.distributed.fsdp → fake_pg.py which requires full distributed support
      that the Jetson PyTorch wheel does not have)
"""
import os
import subprocess
import sys

# Find torchvision install path
result = subprocess.run(
    ["pip", "show", "torchvision"],
    capture_output=True, text=True
)
for line in result.stdout.splitlines():
    if line.startswith("Location:"):
        tv_root = os.path.join(line.split(": ", 1)[1].strip(), "torchvision")
        break
else:
    print("ERROR: torchvision not found", file=sys.stderr)
    sys.exit(1)

print(f"Patching torchvision at {tv_root}")

# --- Patch 1: _meta_registrations.py ---
meta_path = os.path.join(tv_root, "_meta_registrations.py")
with open(meta_path, "w") as f:
    f.write("# Patched: skip meta registrations (NVIDIA torch 2.5.0a0 + CUDA 12.6 incompatibility)\n")
print(f"  [1/3] Patched {meta_path}")

# --- Patch 2: ops/boxes.py — add pure-PyTorch NMS fallback ---
boxes_path = os.path.join(tv_root, "ops", "boxes.py")
with open(boxes_path) as f:
    content = f.read()

# Replace the nms function with a version that falls back to pure PyTorch
old_nms = """    return torch.ops.torchvision.nms(
        boxes,
        scores,
        iou_threshold,
    )"""

new_nms = """    try:
        return torch.ops.torchvision.nms(boxes, scores, iou_threshold)
    except Exception:
        # Pure-PyTorch fallback for Jetson (torchvision _C.so needs CUDA 13, we have 12.6)
        if boxes.numel() == 0:
            return torch.empty((0,), dtype=torch.int64, device=boxes.device)
        x1, y1, x2, y2 = boxes[:, 0], boxes[:, 1], boxes[:, 2], boxes[:, 3]
        areas = (x2 - x1) * (y2 - y1)
        order = scores.argsort(descending=True)
        keep = []
        while order.numel() > 0:
            i = order[0].item()
            keep.append(i)
            if order.numel() == 1:
                break
            xx1 = torch.max(x1[i], x1[order[1:]])
            yy1 = torch.max(y1[i], y1[order[1:]])
            xx2 = torch.min(x2[i], x2[order[1:]])
            yy2 = torch.min(y2[i], y2[order[1:]])
            inter = torch.clamp(xx2 - xx1, min=0) * torch.clamp(yy2 - yy1, min=0)
            iou = inter / (areas[i] + areas[order[1:]] - inter)
            order = order[1:][iou <= iou_threshold]
        return torch.tensor(keep, dtype=torch.int64, device=boxes.device)"""

if old_nms in content:
    content = content.replace(old_nms, new_nms)
    with open(boxes_path, "w") as f:
        f.write(content)
    print(f"  [2/3] Patched {boxes_path} (NMS fallback)")
else:
    print(f"  [2/3] WARNING: Could not find NMS pattern in {boxes_path} — skipping")

# --- Patch 3: ops/roi_align.py — remove torch._dynamo import ---
# torchvision.ops.roi_align imports torch._dynamo.utils.is_compile_supported,
# which cascades into torch.distributed.fsdp → fake_pg.py → torch._C._distributed_c10d.
# On Jetson the distributed backend is missing, so the entire chain crashes.
# torch.compile() / Triton is not supported on aarch64 anyway, so we replace
# the import with an inline function that always returns False.
roi_align_path = os.path.join(tv_root, "ops", "roi_align.py")
with open(roi_align_path) as f:
    roi_content = f.read()

old_dynamo = "from torch._dynamo.utils import is_compile_supported"
new_dynamo = "def is_compile_supported(device_type=\"\"): return False  # Patched: no torch.compile on Jetson"

if old_dynamo in roi_content:
    roi_content = roi_content.replace(old_dynamo, new_dynamo)
    with open(roi_align_path, "w") as f:
        f.write(roi_content)
    print(f"  [3/3] Patched {roi_align_path} (torch._dynamo import removed)")
else:
    print(f"  [3/3] WARNING: Could not find torch._dynamo import in {roi_align_path} — skipping")

# --- Verify ---
print("  Verifying import...")
try:
    import torchvision
    print(f"  torchvision {torchvision.__version__} import OK")
except Exception as e:
    print(f"  ERROR: import failed: {e}", file=sys.stderr)
    sys.exit(1)
