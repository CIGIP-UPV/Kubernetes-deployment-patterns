# Campaign comparison — 20260526-142508

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 65 | 64 | 0.00 | 28.83 | 20.29 | 60.96 | 3.81 | 36.23 | 74.97 | 31.56 | ok |
| microservices | 104 | 100 | 0.00 | 29.38 | 20.19 | 80.36 | 3.54 | 35.98 | 81.93 | 50.86 | ok |
| overlay-canonical | 1098 | 841 | 0.00 | 28.96 | 20.18 | 60.69 | 3.71 | 39.50 | 74.22 | 30.72 | ok |
| dynamic-canonical | 173 | 68 | 0.00 | 206.23 | 4.06 | 257.54 | 33.47 | 22.84 | 31.76 | 29.58 | ok |
