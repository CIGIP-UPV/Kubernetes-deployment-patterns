# Campaign comparison — 20260710-082436

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 523 | 521 | 0.00 | 28.72 | 21.48 | 59.26 | 3.68 | 36.09 | 75.10 | 32.33 | ok |
| microservices | 633 | 630 | 0.00 | 28.51 | 21.77 | 79.16 | 3.65 | 35.99 | 74.18 | 52.58 | ok |
| overlay |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260710-082436/overlay | helm install returned non-zero |
| dynamic-loader | 648 | 554 | 0.00 | 207.82 | 4.04 | 258.58 | 34.28 | 23.37 | 30.17 | 31.82 | ok |
