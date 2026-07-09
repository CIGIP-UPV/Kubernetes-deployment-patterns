# Campaign comparison — 20260522-165043

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 513 | 510 | 0.00 | 25.52 | 21.20 | 59.48 | 0.86 | 43.16 | 40.53 | 28.78 | ok |
| microservices | 634 | 631 | 0.00 | 24.33 | 22.56 | 77.90 | 0.61 | 36.20 | 41.58 | 48.78 | ok |
| overlay-canonical | 1162 | 901 | 0.00 | 25.22 | 21.72 | 58.18 | 0.89 | 43.44 | 36.91 | 28.77 | ok |
| dynamic-canonical | 625 | 526 | 0.00 | 415.46 | 2.14 | 478.78 | 52.65 | 21.51 | 7.98 | 27.88 | ok |
