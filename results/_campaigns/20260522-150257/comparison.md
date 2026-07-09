# Campaign comparison — 20260522-150257

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 69 | 68 | 0.00 | 25.45 | 22.04 | 55.89 | 1.14 | 46.57 | 39.28 | 28.88 | ok |
| microservices | 106 | 102 | 0.00 | 25.66 | 21.19 | 79.50 | 0.71 | 36.49 | 38.32 | 48.69 | ok |
| overlay-canonical | 1119 | 860 | 0.00 | 25.15 | 22.02 | 57.47 | 1.00 | 43.50 | 39.30 | 28.78 | ok |
| dynamic-canonical | 176 | 68 | 0.00 | 403.44 | 2.20 | 466.26 | 48.53 | 21.82 | 6.99 | 27.90 | ok |
