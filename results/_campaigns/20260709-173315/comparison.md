# Campaign comparison — 20260709-173315

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 72 | 68 | 0.00 | 28.33 | 20.74 | 57.49 | 3.78 | 36.95 | 72.92 | 40.61 | ok |
| microservices | 106 | 102 | 0.00 | 28.20 | 22.13 | 78.27 | 3.58 | 35.78 | 72.80 | 52.58 | ok |
| overlay |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260709-173315/overlay | helm install returned non-zero |
| dynamic-loader | 516 | 370 | 0.00 |  |  |  |  | 3.61 | 0.00 | 50.08 | ok |
