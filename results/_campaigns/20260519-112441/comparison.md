# Campaign comparison — 20260519-112441

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 72 | 68 | 0.00 | 38.31 | 9.95 | 108.06 | 12.10 | 20.70 | 51.08 | 32.48 | ok |
| microservices | 104 | 100 | 0.00 | 24.82 | 21.68 | 79.70 | 0.64 | 36.38 | 39.71 | 49.90 | ok |
| overlay-canonical |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260519-112441/overlay-canonical | helm install returned non-zero |
| dynamic-canonical | 135 | 68 | 0.00 | 76.33 | 5.97 | 208.24 | 93.62 | 23.34 | 47.88 | 31.58 | ok |
