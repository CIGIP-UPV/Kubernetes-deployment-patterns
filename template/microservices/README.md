# BYOM: microservices pattern

Only the perception service image is rebuilt with your package; camera, the
other AI services and the dashboard stay stock. This is the pattern property
being exercised: per service lifecycle. An update to your model rebuilds and
re pulls one image only, and your pod can crash or restart without touching
the rest of the graph.

```
export REG=<registry>/<project>
export TAG=mymodel-v1
bash template/microservices/deploy.sh
```
