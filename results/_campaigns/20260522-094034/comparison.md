# Campaign comparison — 20260522-094034

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 71 | 68 | 0.00 | 25.17 | 21.40 | 59.67 | 0.88 | 42.72 | 39.30 | 29.00 | ok |
| microservices | 104 | 100 | 0.00 | 25.53 | 23.12 | 77.40 | 0.77 | 36.48 | 44.54 | 48.77 | ok |
| overlay-canonical | 1059 | 800 | 0.00 | 25.85 | 20.60 | 59.69 | 1.05 | 43.83 | 36.94 | 28.89 | ok |
| dynamic-canonical | 180 | 70 | 0.00 | 406.14 | 2.19 | 466.85 | 54.15 | 21.31 | 6.28 | 28.05 | ok |
