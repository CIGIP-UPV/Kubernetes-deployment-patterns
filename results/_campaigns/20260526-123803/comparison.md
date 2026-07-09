# Campaign comparison — 20260526-123803

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 71 | 68 | 0.00 | 28.56 | 20.47 | 61.19 | 3.94 | 35.96 | 76.57 | 31.62 | ok |
| microservices | 104 | 101 | 0.00 | 27.78 | 21.64 | 78.13 | 4.06 | 35.79 | 74.70 | 50.66 | ok |
| overlay-canonical | 1079 | 821 | 0.00 | 28.91 | 20.62 | 59.62 | 3.73 | 39.38 | 74.55 | 30.74 | ok |
| dynamic-canonical | 174 | 68 | 0.00 | 230.89 | 3.64 | 284.61 | 44.64 | 22.38 | 28.89 | 29.60 | ok |
