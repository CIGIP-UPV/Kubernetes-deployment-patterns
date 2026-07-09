# Campaign comparison — 20260519-092037

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 71 | 68 | 0.00 | 33.02 | 10.18 | 96.81 | 9.66 | 20.88 | 44.81 | 32.47 | ok |
| microservices | 104 | 102 | 0.00 | 24.70 | 22.29 | 78.70 | 0.67 | 36.42 | 40.27 | 50.09 | ok |
| overlay-canonical |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260519-092037/overlay-canonical | helm install returned non-zero |
| dynamic-canonical | 136 | 68 | 0.00 | 70.30 | 6.05 | 205.39 | 34.49 | 22.39 | 46.66 | 31.72 | ok |
