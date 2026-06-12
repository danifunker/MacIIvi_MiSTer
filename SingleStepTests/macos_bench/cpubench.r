/* Custom Finder icon + BNDL for the CpuBench APPL.
 * Green chip outline, "CPU / 68020 / BENCH" inside.
 * Source pixels in make_icons.py — this .r just embeds the hex. */

#include "Types.r"

resource 'BNDL' (128) {
    'CpuB', 0,
    {
        'FREF', { 0, 128 },
        'ICN#', { 0, 128 },
        'icl4', { 0, 128 }
    }
};

resource 'FREF' (128) {
    'APPL', 0, ""
};

/* 32x32 1-bit icon + mask (256 bytes). Mac OS falls back to this on
 * 1-bit displays. */
resource 'ICN#' (128, "CpuBench") {
    {
        $"06 66 66 60 06 66 66 60 1F FF FF F8 30 00 00 0C"
        $"20 00 00 04 E0 00 00 07 E0 1B A4 07 20 22 64 04"
        $"20 23 A4 04 E0 22 24 07 E0 1A 18 07 20 00 00 04"
        $"20 00 00 04 E1 99 99 87 E2 26 46 47 23 9A 4A 44"
        $"22 66 52 44 E1 99 BD 87 E0 00 00 07 20 00 00 04"
        $"23 BE 5A 44 E2 63 62 47 E3 BA E3 C7 22 62 62 44"
        $"23 BE 5A 44 E0 00 00 07 E0 00 00 07 20 00 00 04"
        $"30 00 00 0C 1F FF FF F8 06 66 66 60 06 66 66 60",
        $"06 66 66 60 06 66 66 60 1F FF FF F8 3F FF FF FC"
        $"3F FF FF FC FF FF FF FF FF FF FF FF 3F FF FF FC"
        $"3F FF FF FC FF FF FF FF FF FF FF FF 3F FF FF FC"
        $"3F FF FF FC FF FF FF FF FF FF FF FF 3F FF FF FC"
        $"3F FF FF FC FF FF FF FF FF FF FF FF 3F FF FF FC"
        $"3F FF FF FC FF FF FF FF FF FF FF FF 3F FF FF FC"
        $"3F FF FF FC FF FF FF FF FF FF FF FF 3F FF FF FC"
        $"3F FF FF FC 1F FF FF F8 06 66 66 60 06 66 66 60"
    }
};

/* 32x32 4-bit colour icon (512 bytes) — green outline + black text. */
data 'icl4' (128, "CpuBench") {
        $"00 00 08 80 08 80 08 80 08 80 08 80 08 80 00 00"
        $"00 00 08 80 08 80 08 80 08 80 08 80 08 80 00 00"
        $"00 08 88 88 88 88 88 88 88 88 88 88 88 88 80 00"
        $"00 88 00 00 00 00 00 00 00 00 00 00 00 00 88 00"
        $"00 80 00 00 00 00 00 00 00 00 00 00 00 00 08 00"
        $"88 80 00 00 00 00 00 00 00 00 00 00 00 00 08 88"
        $"88 80 00 00 00 0F F0 FF F0 F0 0F 00 00 00 08 88"
        $"00 80 00 00 00 F0 00 F0 0F F0 0F 00 00 00 08 00"
        $"00 80 00 00 00 F0 00 FF F0 F0 0F 00 00 00 08 00"
        $"88 80 00 00 00 F0 00 F0 00 F0 0F 00 00 00 08 88"
        $"88 80 00 00 00 0F F0 F0 00 0F F0 00 00 00 08 88"
        $"00 80 00 00 00 00 00 00 00 00 00 00 00 00 08 00"
        $"00 80 00 00 00 00 00 00 00 00 00 00 00 00 08 00"
        $"88 80 00 0F F0 0F F0 0F F0 0F F0 0F F0 00 08 88"
        $"88 80 00 F0 00 F0 0F F0 0F 00 0F F0 0F 00 08 88"
        $"00 80 00 FF F0 0F F0 F0 0F 00 F0 F0 0F 00 08 00"
        $"00 80 00 F0 0F F0 0F F0 0F 0F 00 F0 0F 00 08 00"
        $"88 80 00 0F F0 0F F0 0F F0 FF FF 0F F0 00 08 88"
        $"88 80 00 00 00 00 00 00 00 00 00 00 00 00 08 88"
        $"00 80 00 00 00 00 00 00 00 00 00 00 00 00 08 00"
        $"00 80 00 FF F0 FF FF F0 0F 0F F0 F0 0F 00 08 00"
        $"88 80 00 F0 0F F0 00 FF 0F F0 00 F0 0F 00 08 88"
        $"88 80 00 FF F0 FF F0 F0 FF F0 00 FF FF 00 08 88"
        $"00 80 00 F0 0F F0 00 F0 0F F0 00 F0 0F 00 08 00"
        $"00 80 00 FF F0 FF FF F0 0F 0F F0 F0 0F 00 08 00"
        $"88 80 00 00 00 00 00 00 00 00 00 00 00 00 08 88"
        $"88 80 00 00 00 00 00 00 00 00 00 00 00 00 08 88"
        $"00 80 00 00 00 00 00 00 00 00 00 00 00 00 08 00"
        $"00 88 00 00 00 00 00 00 00 00 00 00 00 00 88 00"
        $"00 08 88 88 88 88 88 88 88 88 88 88 88 88 80 00"
        $"00 00 08 80 08 80 08 80 08 80 08 80 08 80 00 00"
        $"00 00 08 80 08 80 08 80 08 80 08 80 08 80 00 00"
};
