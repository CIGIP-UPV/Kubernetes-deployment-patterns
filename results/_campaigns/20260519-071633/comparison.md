# Campaign comparison — 20260519-071633

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 69 | 67 | 0.00 | 35.21 | 10.30 | 97.96 | 10.60 | 20.01 | 51.20 | 32.57 | ok |
| microservices | 104 | 101 | 0.00 | 24.52 | 22.44 | 78.38 | 0.62 | 36.06 | 40.72 | 50.21 | ok |
| overlay-canonical |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260519-071633/overlay-canonical | helm install returned non-zero |
| dynamic-canonical | 136 | 68 | 0.00 | 69.84 | 6.35 | 195.63 | 50.21 | 23.90 | 50.82 | 31.42 | ok |
