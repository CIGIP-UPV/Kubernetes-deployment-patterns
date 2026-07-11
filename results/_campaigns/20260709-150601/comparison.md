# Campaign comparison — 20260709-150601

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 69 | 68 | 0.00 | 28.82 | 20.21 | 59.27 | 3.61 | 36.89 | 74.14 | 32.55 | ok |
| microservices | 254 | 250 | 0.00 | 28.19 | 20.49 | 81.05 | 3.78 | 35.97 | 72.90 | 52.67 | ok |
| overlay |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260709-150601/overlay | helm install returned non-zero |
| dynamic-loader | 646 | 543 | 0.00 | 269.19 | 3.18 | 327.05 | 44.61 | 21.80 | 28.55 | 32.31 | ok |
