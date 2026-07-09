# Campaign comparison — 20260526-090313

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 70 | 68 | 0.00 | 28.59 | 20.34 | 59.85 | 3.72 | 36.65 | 73.60 | 30.86 | ok |
| microservices | 104 | 101 | 0.00 | 28.31 | 20.67 | 79.61 | 3.92 | 35.79 | 74.40 | 51.47 | ok |
| overlay-canonical | 1091 | 830 | 0.00 | 29.44 | 20.08 | 61.01 | 3.25 | 37.92 | 82.89 | 30.81 | ok |
| dynamic-canonical | 172 | 68 | 0.00 | 264.70 | 3.23 | 320.92 | 45.99 | 21.40 | 26.05 | 29.99 | ok |
