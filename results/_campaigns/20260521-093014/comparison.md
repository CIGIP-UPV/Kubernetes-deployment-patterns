# Campaign comparison — 20260521-093014

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 503 | 500 | 0.00 | 25.55 | 21.15 | 58.74 | 1.11 | 45.32 | 36.48 | 29.15 | ok |
| microservices | 644 |  | 0.00 | 25.62 | 21.86 | 57.79 | 36.92 | 43.18 | 39.60 | 24.48 | ok |
| overlay-canonical |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260521-093014/overlay-canonical | helm install returned non-zero |
| dynamic-canonical |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260521-093014/dynamic-canonical | helm install returned non-zero |
