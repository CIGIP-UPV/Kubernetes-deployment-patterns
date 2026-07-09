# Campaign comparison — 20260522-073618

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 524 | 521 | 0.00 | 25.14 | 21.54 | 58.53 | 0.90 | 43.59 | 41.06 | 28.83 | ok |
| microservices | 634 | 631 | 0.00 | 24.28 | 21.90 | 79.50 | 0.60 | 36.15 | 39.84 | 48.77 | ok |
| overlay-canonical | 1131 | 880 | 0.00 | 25.25 | 21.54 | 58.87 | 0.84 | 43.28 | 37.16 | 28.88 | ok |
| dynamic-canonical | 172 | 68 | 0.00 | 390.67 | 2.27 | 453.15 | 54.06 | 21.74 | 6.65 | 27.99 | ok |
