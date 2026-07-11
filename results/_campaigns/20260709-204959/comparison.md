# Campaign comparison — 20260709-204959

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 534 | 531 | 0.00 | 28.45 | 20.38 | 60.16 | 3.84 | 36.18 | 73.24 | 32.42 | ok |
| microservices | 634 | 631 | 0.00 | 28.07 | 20.45 | 81.58 | 4.06 | 36.29 | 73.55 | 52.40 | ok |
| overlay |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260709-204959/overlay | helm install returned non-zero |
| dynamic-loader | 645 | 548 | 0.00 | 245.35 | 3.45 | 301.34 | 46.81 | 22.14 | 24.63 | 31.05 | ok |
