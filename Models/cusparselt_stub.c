/*
 * cuSPARSELt stub library for Jetson Orin (JetPack 6.1)
 *
 * PyTorch 2.5.0a0 (NVIDIA Jetson wheel) links against libcusparseLt.so.0
 * at import time, but cuSPARSELt is NOT included in JetPack 6.1 and has
 * no arm64/Jetson package.  YOLO/LLaVA/Voxtral never call cuSPARSELt
 * functions (it's only used for sparse matmul in niche workloads).
 *
 * This stub exports every cuSPARSELt API symbol that libtorch_cuda.so
 * references, returning CUSPARSE_STATUS_NOT_SUPPORTED (1) so any
 * accidental real call fails gracefully instead of segfaulting.
 *
 * Build:
 *   gcc -shared -o libcusparseLt.so.0 cusparselt_stub.c \
 *       -Wl,-soname,libcusparseLt.so.0
 */

/* cusparseStatus_t values: 0 = SUCCESS, 1 = NOT_SUPPORTED */
#define STUB  { return 1; }

/* ── Handle management ─────────────────────────────────────────────── */
int cusparseLtInit(void *h)                                         STUB
int cusparseLtDestroy(void *h)                                      STUB
int cusparseLtGetVersion(void *h, int *v)                           STUB
int cusparseLtGetProperty(int t, int *v)                            STUB

/* ── Descriptor management ─────────────────────────────────────────── */
int cusparseLtDenseDescriptorInit(void *a, void *b, long r, long c,
    long ld, int align, int dt, int order)                          STUB
int cusparseLtStructuredDescriptorInit(void *a, void *b, long r,
    long c, long ld, int align, int dt, int order, int sp)          STUB
int cusparseLtMatDescriptorDestroy(void *d)                         STUB
int cusparseLtMatDescSetAttribute(void *a, void *d, int attr,
    const void *buf, long sz)                                       STUB
int cusparseLtMatDescGetAttribute(void *a, void *d, int attr,
    void *buf, long sz)                                             STUB

/* ── Matmul descriptor ─────────────────────────────────────────────── */
int cusparseLtMatmulDescriptorInit(void *a, void *b, int op,
    void *ma, void *mb, void *mc, void *md, int comp)               STUB
int cusparseLtMatmulDescSetAttribute(void *a, void *b, int attr,
    const void *buf, long sz)                                        STUB
int cusparseLtMatmulDescGetAttribute(void *a, void *b, int attr,
    void *buf, long sz)                                              STUB

/* ── Algorithm selection ───────────────────────────────────────────── */
int cusparseLtMatmulAlgSelectionInit(void *a, void *b, void *c,
    int alg)                                                        STUB
int cusparseLtMatmulAlgSetAttribute(void *a, void *b, void *c,
    int attr, const void *buf, long sz)                             STUB
int cusparseLtMatmulAlgGetAttribute(void *a, void *b, void *c,
    int attr, void *buf, long sz)                                   STUB

/* ── Plan management ───────────────────────────────────────────────── */
int cusparseLtMatmulPlanInit(void *a, void *b, void *c, void *d)    STUB
int cusparseLtMatmulPlanDestroy(void *p)                            STUB
int cusparseLtMatmulGetWorkspace(void *a, void *p, void *sz)        STUB

/* ── Execution ─────────────────────────────────────────────────────── */
int cusparseLtMatmul(void *a, void *p, const void *alpha,
    const void *A, const void *B, const void *beta, const void *C,
    void *D, void *ws, void **streams, int n)                       STUB
int cusparseLtMatmulSearch(void *a, void *p, const void *alpha,
    const void *A, const void *B, const void *beta, const void *C,
    void *D, void *ws, void **streams, int n)                       STUB

/* ── Pruning ───────────────────────────────────────────────────────── */
int cusparseLtSpMMAPrune(void *a, void *b, const void *d,
    void *dd, int pr, void *s)                                      STUB
int cusparseLtSpMMAPrune2(void *a, void *b, int act, int op,
    const void *d, void *dd, int pr, void *s)                       STUB
int cusparseLtSpMMAPruneCheck(void *a, void *b, const void *d,
    int *valid, void *s)                                            STUB
int cusparseLtSpMMAPruneCheck2(void *a, void *b, int act, int op,
    const void *d, int *valid, void *s)                             STUB

/* ── Compression ───────────────────────────────────────────────────── */
int cusparseLtSpMMACompressedSize(void *a, void *p, void *csz,
    void *cbs)                                                      STUB
int cusparseLtSpMMACompressedSize2(void *a, void *b, void *csz,
    void *cbs)                                                      STUB
int cusparseLtSpMMACompress(void *a, void *p, const void *d,
    void *cd, void *cb, void *s)                                    STUB
int cusparseLtSpMMACompress2(void *a, void *b, int act,int op,
    const void *d, void *cd, void *cb, void *s)                     STUB
