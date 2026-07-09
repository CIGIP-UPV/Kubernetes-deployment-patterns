# Campaign comparison — 20260518-094127

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 71 | 68 | 0.00 | 35.89 | 10.24 | 96.31 | 10.54 | 21.04 | 54.99 | 33.25 | ok |
| microservices | 104 | 101 | 0.00 | 25.04 | 21.65 | 79.90 | 0.63 | 36.43 | 40.57 | 50.88 | ok |
| overlay-canonical |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260518-094127/overlay-canonical | helm install returned non-zero |
| dynamic-canonical |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260518-094127/dynamic-canonical | helm install returned non-zero |
