| variant_cpu_scsi.s — per-variant constants for CPU bench on SCSI.
| Linked alongside bench_main.c + payload_entry_cpu.s.

    .data
    .global g_results_offset
    .global g_results_max_bytes
| 8-byte magic tag the build script can grep for in the assembled .bin
| to patch the next two longs at link/build time. Lets us avoid hard-
| coding the /Results.jsonl partition offset — it varies with payload
| size and disk layout.
g_results_marker:    .ascii  "RJSNLTAG"   | findable signature
g_results_offset:    .long 0xDEADBEEF     | patched by build script
g_results_max_bytes: .long 409600         | 400 KB pre-allocation
