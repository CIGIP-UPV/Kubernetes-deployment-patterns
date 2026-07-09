# Campaign comparison — 20260525-154044

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 533 | 530 | 0.00 | 28.61 | 20.29 | 60.10 | 3.90 | 36.00 | 74.94 | 30.66 | ok |
| microservices | 644 | 640 | 0.00 | 29.40 | 20.16 | 80.53 | 3.63 | 36.18 | 83.19 | 50.72 | ok |
| overlay-canonical | 1162 | 901 | 0.00 | 29.52 | 20.00 | 62.53 | 3.29 | 38.35 | 81.22 | 30.65 | ok |
| dynamic-canonical | 626 | 527 | 0.00 | 268.24 | 3.17 | 330.95 | 29.76 | 21.36 | 27.68 | 30.30 | ok |
