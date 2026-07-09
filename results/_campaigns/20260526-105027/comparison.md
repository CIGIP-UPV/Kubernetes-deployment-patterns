# Campaign comparison — 20260526-105027

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 71 | 68 | 0.00 | 28.67 | 20.41 | 60.26 | 3.74 | 36.25 | 75.02 | 31.70 | ok |
| microservices | 106 | 102 | 0.00 | 28.43 | 20.34 | 80.88 | 4.07 | 36.37 | 76.20 | 50.66 | ok |
| overlay-canonical | 1106 | 851 | 0.00 | 29.33 | 20.08 | 61.55 | 3.21 | 39.47 | 75.07 | 30.99 | ok |
| dynamic-canonical | 176 | 68 | 0.00 | 251.55 | 3.41 | 304.64 | 47.40 | 21.63 | 27.32 | 29.69 | ok |
