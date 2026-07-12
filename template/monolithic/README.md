# BYOM: monolithic pattern

Your package is compiled into the workspace the chart already sources
(`/opt/ros2_monolithic_ws`), so the stock chart starts it with no edits. The
whole stack (camera, your model, the other AI nodes, all as separate OS
processes) ships as one image: any update implies rebuilding and re pulling
the full image, which is exactly the lifecycle property this pattern trades.

```
export REG=<registry>/<project>
export TAG=mymodel-v1
bash template/monolithic/deploy.sh
```

Cross building from an x86 host needs QEMU (`docker run --privileged --rm
tonistiigi/binfmt --install arm64`) or an arm64 builder.
