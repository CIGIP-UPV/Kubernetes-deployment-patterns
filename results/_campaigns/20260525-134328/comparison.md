# Campaign comparison — 20260525-134328

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 71 | 68 | 0.00 | 28.88 | 20.57 | 59.85 | 3.43 | 35.85 | 70.90 | 31.22 | ok |
| microservices | 663 | 661 | 0.00 | 28.56 | 20.45 | 80.12 | 3.64 | 35.98 | 75.44 | 51.75 | ok |
| overlay-canonical | 1119 | 861 | 0.00 | 29.31 | 20.12 | 59.67 | 3.27 | 41.58 | 74.07 | 30.74 | ok |
| dynamic-canonical | 184 | 68 | 0.00 | 253.94 | 3.35 | 309.94 | 47.44 | 21.59 | 24.42 | 29.55 | ok |
