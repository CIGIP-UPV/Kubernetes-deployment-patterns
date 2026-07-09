# Campaign comparison — 20260526-182607

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 533 | 531 | 0.00 | 29.67 | 21.37 | 58.51 | 3.28 | 35.90 | 82.64 | 30.73 | ok |
| microservices | 656 | 652 | 0.00 | 28.81 | 20.69 | 79.80 | 3.94 | 35.97 | 75.32 | 50.95 | ok |
| overlay-canonical | 1143 | 880 | 0.00 | 28.98 | 20.20 | 61.05 | 3.18 | 38.63 | 75.56 | 30.77 | ok |
| dynamic-canonical | 624 | 526 | 0.00 | 256.31 | 3.31 | 314.97 | 40.40 | 21.58 | 27.84 | 30.32 | ok |
