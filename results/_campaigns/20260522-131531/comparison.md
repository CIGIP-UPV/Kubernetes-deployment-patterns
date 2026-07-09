# Campaign comparison — 20260522-131531

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 71 | 68 | 0.00 | 25.21 | 21.25 | 57.43 | 0.92 | 46.50 | 37.86 | 28.98 | ok |
| microservices | 104 | 101 | 0.00 | 24.64 | 21.80 | 78.59 | 0.64 | 36.40 | 39.41 | 48.79 | ok |
| overlay-canonical | 1104 | 830 | 0.00 | 25.49 | 21.61 | 56.84 | 0.96 | 43.80 | 37.49 | 28.78 | ok |
| dynamic-canonical | 172 | 68 | 0.00 | 411.51 | 2.16 | 476.63 | 53.52 | 21.47 | 7.82 | 27.99 | ok |
