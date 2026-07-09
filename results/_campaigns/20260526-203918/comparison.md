# Campaign comparison — 20260526-203918

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 533 | 530 | 0.00 | 28.72 | 20.93 | 58.39 | 3.63 | 36.71 | 76.35 | 30.71 | ok |
| microservices | 646 | 642 | 0.00 | 28.23 | 21.44 | 78.42 | 3.88 | 35.95 | 77.95 | 51.81 | ok |
| overlay-canonical | 1150 | 891 | 0.00 | 29.11 | 21.25 | 59.09 | 3.32 | 39.08 | 76.52 | 30.81 | ok |
| dynamic-canonical | 623 | 527 | 0.00 | 272.48 | 3.17 | 326.61 | 45.43 | 21.30 | 24.62 | 30.32 | ok |
