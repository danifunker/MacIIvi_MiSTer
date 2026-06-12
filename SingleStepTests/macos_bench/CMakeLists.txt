cmake_minimum_required(VERSION 3.10)
project(MacOsBench C CXX)

# One Mac OS APPL in this directory:
#   CpuBench        — user-mode CPU instruction tests (cpu_tests.h)
#
# The Macintosh IIvi target ships without an FPU (the 68882 socket is
# empty by default), so the FPU / CPU+FPU benches from the Mac II
# project are not carried over. PMMU tests are privileged and cannot
# run from a user-mode APPL — they live in preboot/supervisor_bench/.

add_application(CpuBench CONSOLE
    cpu_bench.c
    cpubench.r
    CREATOR CpuB
)
