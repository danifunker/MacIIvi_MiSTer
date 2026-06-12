| exception_handlers.s — Step D continuation.
| Vectors point here. Each handler records the exception vector +
| frame info into the current test's Snapshot, fixes up SR/PC on
| the supervisor stack to skip the faulting instruction, then RTE.
|
| Stub: single handler that just RTEs (unsafe — real impl must
| repair the stack frame per 68020 PRM §6.4).

    .text
    .global exc_default
exc_default:
    rte
