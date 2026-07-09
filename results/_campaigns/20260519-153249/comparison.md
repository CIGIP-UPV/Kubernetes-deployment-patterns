# Campaign comparison — 20260519-153249

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 72 | 68 | 0.00 | 37.40 | 9.88 | 111.42 | 12.49 | 21.29 | 51.81 | 32.99 | ok |
| microservices | 104 | 101 | 0.00 | 24.46 | 22.36 | 78.45 | 0.60 | 36.24 | 39.97 | 50.08 | ok |
| overlay-canonical |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260519-153249/overlay-canonical | helm install returned non-zero |
| dynamic-canonical | 136 | 70 | 0.00 | 74.91 | 5.71 | 214.90 | 85.32 | 22.46 | 46.38 | 31.49 | ok |
