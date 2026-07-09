# Campaign comparison — 20260522-211648

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 533 | 530 | 0.00 | 25.15 | 21.69 | 58.52 | 0.86 | 42.86 | 43.10 | 28.76 | ok |
| microservices | 635 | 631 | 0.00 | 24.87 | 22.03 | 78.78 | 0.64 | 36.58 | 40.85 | 49.51 | ok |
| overlay-canonical | 1131 | 870 | 0.00 | 25.06 | 21.87 | 57.60 | 0.85 | 42.89 | 42.32 | 28.80 | ok |
| dynamic-canonical | 612 | 515 | 0.00 | 412.55 | 2.16 | 477.67 | 57.80 | 21.61 | 7.93 | 27.81 | ok |
