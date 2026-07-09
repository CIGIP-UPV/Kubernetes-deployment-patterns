# Campaign comparison — 20260522-190342

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 533 | 530 | 0.00 | 25.84 | 22.81 | 57.06 | 1.03 | 43.38 | 44.24 | 28.74 | ok |
| microservices | 633 | 630 | 0.00 | 24.38 | 22.60 | 77.18 | 0.68 | 36.25 | 40.85 | 48.82 | ok |
| overlay-canonical | 1161 | 900 | 0.00 | 25.23 | 21.26 | 59.03 | 0.84 | 43.45 | 36.60 | 28.79 | ok |
| dynamic-canonical | 622 | 526 | 0.00 | 330.53 | 2.67 | 383.19 | 30.18 | 22.48 | 4.71 | 28.51 | ok |
