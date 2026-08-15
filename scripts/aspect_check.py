#!/usr/bin/env python3
"""Offline gate for the OSD "Original" aspect ratio (MacIIvi.sv video_freak).

The Verilator sim never instantiates sys/video_freak.sv (no framework), so
the scaler's integer math has NO simulation coverage — this script is the
regression gate instead. It is a faithful model of
sys/video_freak.sv :: video_scale_int (sys_udiv/sys_umul = floor division,
12-bit results), state numbers in comments match the RTL's cnt values.

History it guards: until 2026-08-08 the "Original" aspect was 256:171 — the
Mac Plus 512x342 screen, inherited through the LC-family import. Both real
sources of this machine (mdc824 640x480 sense-6, 512x384 12" RGB) are 4:3.
The 1.497:1 request made integer-scale modes ask for a picture WIDER than
5:4 panels (V-Integer at 1280x1024: htarget = 960*256/171 = 1437 px ->
blank screen) and squished forced-1080p output. The fix is ARX/ARY = 4:3;
this script fails if the overflow class ever comes back.

Run:  python3 scripts/aspect_check.py   (exit 0 = all gates pass)
"""

import sys

M12 = 0xFFF  # sys_udiv/sys_umul results are consumed as [11:0]


def scale_int(W, H, SCALE, hsize, vsize, arx, ary):
    """Model of video_scale_int. Returns ('ratio', x, y) for pass-through
    or ('size', width, height) when integer scaling produced a size."""
    # !SCALE || (!ary_i && arx_i) -> pass the ratio through untouched
    if SCALE == 0 or (ary == 0 and arx != 0):
        return ('ratio', arx, ary)

    k = (H // vsize) & M12                      # cnt0
    if k == 0:                                  # cnt1: panel shorter than source
        return ('ratio', arx, ary)
    oheight = (vsize * k) & M12                 # cnt1/2

    htarget = None
    if ary == 0:                                # cnt2 -> width path (arx==0 too)
        div_num = W                             # cnt8 leaves div_num = W
        f2 = (W // hsize) & M12
        f2 = f2 if f2 else 1                    # cnt9/10: max(f2, 1)
        hinteger = (hsize * f2) & M12
        oheight = (vsize * f2) & M12            # cnt10/11
    else:
        htarget = ((oheight * arx) // ary) & M12  # cnt3/4/5
        div_num = htarget                       # cnt5 leaves div_num = htarget
        f = (htarget // hsize) & M12            # cnt5
        cand = (hsize * (f if f else 1)) & M12  # cnt6: max(f, 1)
        if cand <= W:                           # cnt7: fits -> jump to cnt12
            hinteger = cand
        else:                                   # falls through to cnt8..11
            div_num = W
            f2 = (W // hsize) & M12
            f2 = f2 if f2 else 1
            hinteger = (hsize * f2) & M12
            oheight = (vsize * f2) & M12

    wideres = hinteger + hsize                  # cnt12
    narrow = (htarget is not None
              and (htarget - hinteger) <= (wideres - htarget)) or wideres > W
    wres = hinteger if (htarget is not None and hinteger == htarget) else wideres

    if SCALE == 2:                              # cnt13: HV-Integer- (Narrower)
        aw = hinteger
    elif SCALE == 3:                            # HV-Integer+ (Wider)
        aw = hinteger if wres > W else wres
    elif SCALE == 4:                            # HV-Integer (closest) — not
        aw = hinteger if narrow else wres       # reachable from this core's
    else:                                       # 2-bit status[13:12], modeled
        aw = div_num                            # for completeness. SCALE==1:
    return ('size', aw, oheight)                # V-Integer -> div_num


SOURCES = [("VGA 640x480 (sense 6)", 640, 480),
           ("12\" RGB 512x384", 512, 384)]
PANELS = [(1280, 720), (1920, 1080), (1280, 1024),
          (1024, 768), (2560, 1440), (800, 600)]
MODES = [(1, "V-Integer"), (2, "Narrower HV-Int"), (3, "Wider HV-Int")]

FIXED_AR = (4, 3)      # the shipped "Original" aspect
PLUS_AR = (256, 171)   # the Mac Plus leftover this replaced

failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)
        print("FAIL: " + msg)


# ---- gate 1+2: with 4:3, every combination fits, is exactly 4:3, and is an
# integer multiple of the source ------------------------------------------
print("== fixed AR %d:%d ==" % FIXED_AR)
for sname, hs, vs in SOURCES:
    for W, H in PANELS:
        for sc, mname in MODES:
            kind, w, h = scale_int(W, H, sc, hs, vs, *FIXED_AR)
            if kind == 'ratio':
                # panel shorter than source (e.g. 512x384 has none here);
                # pass-through of 4:3 is correct by definition
                check((w, h) == FIXED_AR,
                      "%s %dx%d %s: ratio fallback %s:%s" % (sname, W, H, mname, w, h))
                continue
            print("  %-22s %4dx%-4d %-16s -> %4dx%d" % (sname, W, H, mname, w, h))
            check(w <= W, "%s %dx%d %s: width %d overflows panel %d"
                  % (sname, W, H, mname, w, W))
            check(h <= H, "%s %dx%d %s: height %d overflows panel %d"
                  % (sname, W, H, mname, h, H))
            check(w * 3 == h * 4, "%s %dx%d %s: %dx%d is not 4:3"
                  % (sname, W, H, mname, w, h))
            check(w % hs == 0 and h % vs == 0 and (w // hs) == (h // vs),
                  "%s %dx%d %s: %dx%d is not an integer multiple of %dx%d"
                  % (sname, W, H, mname, w, h, hs, vs))

# ---- spot-check table from the fix's analysis (VGA source) ---------------
EXPECT = {(1280, 720): (640, 480), (1920, 1080): (1280, 960),
          (1280, 1024): (1280, 960), (2560, 1440): (1920, 1440)}
for (W, H), want in EXPECT.items():
    for sc, mname in MODES:
        kind, w, h = scale_int(W, H, sc, 640, 480, *FIXED_AR)
        check((kind, (w, h)) == ('size', want),
              "spot %dx%d %s: got %s %sx%s want %sx%s"
              % (W, H, mname, kind, w, h, want[0], want[1]))

# ---- model self-test: the OLD ratio must reproduce the documented bugs ---
# (guards the model itself against drifting away from the RTL)
kind, w, h = scale_int(1280, 1024, 1, 640, 480, *PLUS_AR)
check((kind, w, h) == ('size', 1437, 960),
      "self-test: 256:171 V-Int at 1280x1024 should ask 1437x960 (got %s %sx%s)"
      % (kind, w, h))
kind, w, h = scale_int(1024, 768, 1, 512, 384, *PLUS_AR)
check((kind, w, h) == ('size', 1149, 768),
      "self-test: 256:171 V-Int 12\" at 1024x768 should ask 1149x768 (got %s %sx%s)"
      % (kind, w, h))
kind, w, h = scale_int(1280, 720, 3, 640, 480, *PLUS_AR)
check((kind, w, h) == ('size', 1280, 480),
      "self-test: 256:171 Wider at 1280x720 should ask 1280x480 (got %s %sx%s)"
      % (kind, w, h))

if failures:
    print("\n%d FAILURE(S)" % len(failures))
    sys.exit(1)
print("\nPASS: no overflow on any panel; every integer-scale result is 4:3")
