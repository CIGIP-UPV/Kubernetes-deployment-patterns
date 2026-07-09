# Campaign comparison — 20260521-100421

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 523 | 520 | 0.00 | 24.74 | 21.82 | 57.77 | 0.85 | 42.98 | 36.91 | 28.87 | ok |
| microservices | 634 | 630 | 0.00 | 25.00 | 23.52 | 76.74 | 0.79 | 36.42 | 41.94 | 49.13 | ok |
| overlay-canonical | 1145 | 891 | 0.00 | 24.97 | 21.72 | 58.02 | 0.95 | 43.07 | 40.84 | 28.87 | ok |
| dynamic-canonical | 628 | 527 | 0.00 | 345.46 | 2.54 | 406.11 | 42.58 | 22.18 | 5.78 | 28.19 | ok |
