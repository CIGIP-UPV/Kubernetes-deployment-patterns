# Campaign comparison — 20260526-161225

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 550 | 546 | 0.00 | 28.79 | 20.46 | 60.00 | 3.58 | 36.32 | 78.41 | 30.88 | ok |
| microservices | 645 | 642 | 0.00 | 28.09 | 20.23 | 81.42 | 4.04 | 36.26 | 72.28 | 51.44 | ok |
| overlay-canonical | 1152 | 890 | 0.00 | 28.56 | 20.75 | 57.89 | 3.67 | 40.62 | 77.81 | 30.86 | ok |
| dynamic-canonical | 628 | 533 | 0.00 | 202.60 | 4.14 | 252.88 | 29.27 | 22.85 | 31.55 | 30.39 | ok |
