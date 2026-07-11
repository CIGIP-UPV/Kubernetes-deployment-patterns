# Campaign comparison — 20260709-194649

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 72 | 68 | 0.00 | 29.67 | 20.29 | 58.79 | 3.50 | 36.75 | 82.53 | 32.31 | ok |
| microservices | 104 | 101 | 0.00 | 28.83 | 21.43 | 80.74 | 3.72 | 36.44 | 75.92 | 52.13 | ok |
| overlay |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260709-194649/overlay | helm install returned non-zero |
| dynamic-loader | 257 | 68 | 0.00 | 258.33 | 3.34 | 310.55 | 50.18 | 24.30 | 41.88 | 53.55 | ok |
