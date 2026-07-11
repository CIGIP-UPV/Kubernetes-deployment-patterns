# Campaign comparison — 20260709-184011

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 71 | 68 | 0.00 | 28.14 | 20.85 | 59.10 | 4.00 | 35.72 | 74.19 | 32.51 | ok |
| microservices | 104 | 101 | 0.00 | 28.76 | 21.83 | 78.72 | 3.63 | 35.89 | 76.56 | 52.37 | ok |
| overlay |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260709-184011/overlay | helm install returned non-zero |
| dynamic-loader | 500 | 379 | 0.00 |  |  |  |  | 3.70 | 0.00 | 28.36 | ok |
