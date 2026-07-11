# Campaign comparison — 20260709-221644

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 523 | 520 | 0.00 | 28.47 | 20.57 | 59.79 | 3.61 | 35.66 | 75.44 | 32.50 | ok |
| microservices | 684 | 681 | 0.00 | 29.47 | 20.07 | 82.36 | 3.61 | 36.72 | 80.81 | 53.04 | ok |
| overlay |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260709-221644/overlay | helm install returned non-zero |
| dynamic-loader | 643 | 548 | 0.00 | 211.34 | 3.97 | 262.20 | 27.72 | 23.00 | 26.85 | 31.18 | ok |
