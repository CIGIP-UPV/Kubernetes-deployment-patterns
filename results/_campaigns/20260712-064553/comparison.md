# Campaign comparison — 20260712-064553

| Pattern | T_install (s) | T_ready_sys (s) | S_img (GB) | T_inf avg (ms) | FPS | T_e2e avg (ms) | J_inf (ms) | U_CPU (%) | U_GPU (%) | U_RAM (%) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| monolithic | 72 | 68 | 0.00 | 26.52 | 21.64 | 58.04 | 3.03 | 35.64 | 57.04 | 31.97 | ok |
| microservices | 104 | 100 | 0.00 | 26.26 | 22.85 | 77.58 | 3.22 | 35.07 | 58.83 | 52.16 | ok |
| overlay | 1269 | 971 | 0.00 | 26.24 | 21.38 | 58.49 | 3.34 | 35.48 | 56.54 | 31.92 | ok |
| dynamic-loader | 523 | 402 | 0.00 |  |  |  |  | 3.64 | 0.00 | 28.09 | ok |
