# Campaign comparison — 20260507-123512

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 513 | 510 | 0.00 | 38.46 | 9.70 | 112.83 | 12.70 | 22.51 | 51.68 | 33.34 | ok |
| microservices | 643 | 641 | 0.00 | 37.44 | 10.11 | 134.46 | 12.69 | 24.56 | 50.77 | 53.14 | ok |
| dynamic-canonical | 137 | 69 | 0.00 | 76.54 | 5.45 | 224.67 | 74.50 | 24.24 | 46.66 | 32.63 | ok |
| overlay-canonical |  |  |  |  |  |  |  |  |  | /home/administrador/Kubernetes-deployment-patterns/results/_campaigns/20260507-123512/overlay-canonical | helm install returned non-zero |
