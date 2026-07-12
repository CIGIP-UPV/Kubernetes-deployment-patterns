# Campaign comparison — 20260712-132200

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 72 | 69 | 0.00 | 25.27 | 21.45 | 58.42 | 2.35 | 35.43 | 46.84 | 36.64 | ok |
| microservices | 104 | 101 | 0.00 | 25.83 | 22.52 | 79.00 | 2.30 | 35.22 | 47.88 | 51.84 | ok |
| overlay | 1312 | 1011 | 0.00 | 25.28 | 21.26 | 58.14 | 2.23 | 36.31 | 46.27 | 32.00 | ok |
| dynamic-loader |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260712-132200/dynamic-loader | helm install returned non-zero |
