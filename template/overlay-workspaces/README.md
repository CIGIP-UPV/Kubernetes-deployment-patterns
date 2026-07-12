# BYOM: overlay workspaces pattern

Your package travels inside the overlay layer: the carrier is extracted on the
cloud node, served over HTTP, fetched by the edge Init Container and sourced
by the runtime on top of the immutable base image. An update to your model
re publishes the carrier only (or a single layer, with `overlay.layered=true`),
never the base platform image, which is the OTA property of this pattern.

Note the deployment cost characterised in the paper: with a recreated
PersistentVolumeClaim the fully clean deployment of this pattern is the
slowest of the four; its strength is the operating point restart (hostPath
persistence) and the bounded update payload.

```
export REG=<registry>/<project>
export TAG=mymodel-v1
bash template/overlay-workspaces/deploy.sh
```

The carrier image is large (it embeds the full payload of this repository).
For a lean start you can also build a reduced carrier from scratch following
Models/ros2_overlay_pack/docker/Dockerfile.
