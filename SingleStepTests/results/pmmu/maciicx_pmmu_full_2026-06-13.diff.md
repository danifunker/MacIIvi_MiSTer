# PMMU corpus comparison — MAME baseline vs Macintosh IIcx (real 68030)

```
identity_probe: attempting
identity_probe: ok
FAIL PMOVE PSR w/r (write $FFFF)
      mmu.psr: got 0xee47, expected 0xffff
      window $1800: 2 byte diffs at +['0x20', '0x21']
FAIL PTESTR #5,(A0),#7 root limit violation (L)
      mmu.psr: got 0x4400, expected 0x401
FAIL PTESTR #5,(A0),#7 through TT0 (T)
      mmu.psr: got 0x1, expected 0x40

37 passed, 3 failed, 0 skipped (corpus rows: 40)
```
