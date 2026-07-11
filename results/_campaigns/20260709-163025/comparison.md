# Campaign comparison — 20260709-163025

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 69 | 67 | 0.00 | 28.39 | 20.49 | 60.63 | 3.66 | 36.45 | 72.02 | 32.52 | ok |
| microservices | 104 | 100 | 0.00 | 28.12 | 20.49 | 80.91 | 3.84 | 35.87 | 73.62 | 52.32 | ok |
| overlay |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260709-163025/overlay | helm install returned non-zero |
| dynamic-loader | 237 | 69 | 0.00 | 252.35 | 3.42 | 304.71 | 41.52 | 24.71 | 42.23 | 53.69 | ok |
