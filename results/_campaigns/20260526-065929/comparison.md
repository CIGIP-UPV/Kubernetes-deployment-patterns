# Campaign comparison — 20260526-065929

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 523 | 520 | 0.00 | 28.76 | 20.47 | 60.00 | 3.68 | 36.42 | 75.64 | 31.66 | ok |
| microservices | 633 | 631 | 0.00 | 29.05 | 20.36 | 80.36 | 3.76 | 36.03 | 81.79 | 50.69 | ok |
| overlay-canonical | 1090 | 831 | 0.00 | 28.84 | 19.91 | 62.58 | 3.32 | 38.98 | 75.72 | 31.62 | ok |
| dynamic-canonical | 178 | 68 | 0.00 | 270.36 | 3.19 | 324.78 | 45.28 | 21.23 | 26.55 | 30.62 | ok |
