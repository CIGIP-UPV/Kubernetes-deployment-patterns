# Campaign comparison — 20260710-065547

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 523 | 520 | 0.00 | 28.06 | 20.68 | 59.46 | 4.00 | 35.72 | 74.93 | 32.33 | ok |
| microservices | 674 | 671 | 0.00 | 28.56 | 20.74 | 81.14 | 3.95 | 35.77 | 74.55 | 52.51 | ok |
| overlay |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260710-065547/overlay | helm install returned non-zero |
| dynamic-loader | 682 | 577 | 0.00 | 256.47 | 3.32 | 313.29 | 55.73 | 22.08 | 26.01 | 31.83 | ok |
