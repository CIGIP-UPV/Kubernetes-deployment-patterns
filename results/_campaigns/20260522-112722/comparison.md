# Campaign comparison — 20260522-112722

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 71 | 68 | 0.00 | 25.43 | 21.13 | 58.16 | 1.06 | 45.13 | 38.16 | 28.95 | ok |
| microservices | 104 | 100 | 0.00 | 25.58 | 22.99 | 77.73 | 0.81 | 36.20 | 42.26 | 48.73 | ok |
| overlay-canonical | 1086 | 831 | 0.00 | 25.93 | 22.60 | 56.66 | 1.15 | 43.53 | 38.64 | 28.81 | ok |
| dynamic-canonical | 233 | 68 | 0.00 | 549.93 | 1.67 | 610.91 | 63.68 | 22.65 | 3.63 | 49.71 | ok |
