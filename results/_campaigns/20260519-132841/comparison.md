# Campaign comparison — 20260519-132841

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 71 | 68 | 0.00 | 37.78 | 10.01 | 109.09 | 12.63 | 21.41 | 49.54 | 32.35 | ok |
| microservices | 104 | 100 | 0.00 | 23.99 | 22.00 | 79.22 | 0.59 | 36.24 | 40.54 | 49.88 | ok |
| overlay-canonical |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260519-132841/overlay-canonical | helm install returned non-zero |
| dynamic-canonical | 133 | 68 | 0.00 | 70.42 | 6.23 | 197.53 | 69.96 | 22.49 | 46.31 | 31.53 | ok |
