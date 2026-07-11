# Campaign comparison — 20260710-095124

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 523 | 521 | 0.00 | 28.55 | 20.79 | 58.83 | 3.94 | 36.25 | 73.58 | 32.16 | ok |
| microservices | 663 | 661 | 0.00 | 28.17 | 20.79 | 80.79 | 4.14 | 35.83 | 72.65 | 52.98 | ok |
| overlay |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260710-095124/overlay | helm install returned non-zero |
| dynamic-loader | 658 | 559 | 0.00 | 205.88 | 4.07 | 256.86 | 38.75 | 23.47 | 31.99 | 31.10 | ok |
