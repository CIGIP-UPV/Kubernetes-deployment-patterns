# Campaign comparison — 20260711-223121

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 69 | 67 | 0.00 | 28.32 | 20.41 | 60.75 | 3.62 | 35.85 | 72.07 | 32.16 | ok |
| microservices | 104 | 101 | 0.00 | 28.02 | 20.79 | 80.27 | 4.21 | 35.63 | 74.55 | 52.86 | ok |
| overlay | 1304 | 1001 | 0.00 | 28.57 | 21.92 | 56.06 | 3.81 | 36.32 | 75.84 | 32.06 | ok |
| dynamic-loader | 429 | 296 | 0.00 |  |  |  |  | 3.53 | 0.00 | 28.28 | ok |
