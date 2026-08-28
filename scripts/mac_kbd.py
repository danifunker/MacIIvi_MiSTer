#!/usr/bin/env python3
"""Inject keyboard events into the MiSTer Remote's virtual keyboard (mrext)
via evdev, for guest-Mac keystrokes the ws kbd: API can't express (modifier
combos like Command-B). Streams struct-packed input_event records over ssh
into the mrext KEYBOARD event device.

The core maps PS/2 LEFT/RIGHT ALT -> ADB Command (rtl/ps2_kbd.sv), so the
Mac Command key = KEY_LEFTALT here.

Every press is paired with a release in the same stream (the July-2026
lesson: an orphaned key-up latches a key down in the guest forever). The
stream also ends with a belt-and-braces release of the modifiers it used.

Usage:
  python scripts/mac_kbd.py [--dev /dev/input/eventN] TOKEN [TOKEN...]
Tokens:
  cmd:x        Command-<x>  (hold LEFTALT, tap x, release)   e.g. cmd:b
  key:name     tap a key: enter esc space tab up down left right delete
               or a single letter/digit
  type:text    type text (letters/digits/space/dot/dash; case-insensitive)
  sleep:N      pause N seconds (float ok)

Find the device number: cat /proc/bus/input/devices, Name="mrext" (the
keyboard one; NOT mrext-mouse). 2026-08-16 on .143 it is event12.
"""
import argparse, os, struct, subprocess, sys, time

CODES = {
    'a':30,'b':48,'c':46,'d':32,'e':18,'f':33,'g':34,'h':35,'i':23,'j':36,
    'k':37,'l':38,'m':50,'n':49,'o':24,'p':25,'q':16,'r':19,'s':31,'t':20,
    'u':22,'v':47,'w':17,'x':45,'y':21,'z':44,
    '1':2,'2':3,'3':4,'4':5,'5':6,'6':7,'7':8,'8':9,'9':10,'0':11,
    'enter':28,'esc':1,'space':57,'tab':15,'up':103,'down':108,
    'left':105,'right':106,'delete':14,'dot':52,'.':52,'dash':12,'-':12,
    'alt':56,'shift':42,
}

def ev(t, c, v):
    return struct.pack('<IIHHi', 0, 0, t, c, v)

def syn():
    return ev(0, 0, 0)

def build(tokens, key_pace, stroke_pace):
    out = []
    def tap(code):
        out.append((ev(1, code, 1) + syn(), key_pace))
        out.append((ev(1, code, 0) + syn(), stroke_pace))
    for tok in tokens:
        kind, _, arg = tok.partition(':')
        if kind == 'sleep':
            out.append((b'', float(arg)))
        elif kind == 'cmd':
            code = CODES[arg.lower()]
            out.append((ev(1, 56, 1) + syn(), 0.12))       # Command down
            tap(code)
            out.append((ev(1, 56, 0) + syn(), stroke_pace)) # Command up
        elif kind == 'key':
            tap(CODES[arg.lower()])
        elif kind == 'type':
            for ch in arg:
                if ch == ' ':
                    tap(CODES['space'])
                else:
                    tap(CODES[ch.lower()])
        else:
            raise SystemExit(f'bad token: {tok}')
    # final safety: release the modifiers this tool ever holds
    out.append((ev(1, 56, 0) + syn(), 0.02))
    out.append((ev(1, 42, 0) + syn(), 0.02))
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dev', default=os.environ.get('KBD_DEV', '/dev/input/event12'))
    ap.add_argument('--host', default=os.environ.get('MISTER_HOST'))
    ap.add_argument('--ssh-key', default=os.environ.get('MISTER_SSH_KEY'))
    ap.add_argument('--key-pace', type=float, default=0.06)     # down->up
    ap.add_argument('--stroke-pace', type=float, default=0.12)  # between strokes
    ap.add_argument('tokens', nargs='+')
    a = ap.parse_args()
    if not a.host or not a.ssh_key:
        raise SystemExit('need MISTER_HOST/MISTER_SSH_KEY (source scripts/local.env)')
    seq = build(a.tokens, a.key_pace, a.stroke_pace)
    p = subprocess.Popen(
        ['ssh', '-i', a.ssh_key, '-o', 'StrictHostKeyChecking=no',
         f'root@{a.host}', f'cat > {a.dev} && echo KBD_STREAM_DELIVERED'],
        stdin=subprocess.PIPE)
    for chunk, pause in seq:
        if chunk:
            p.stdin.write(chunk)
            p.stdin.flush()
        if pause:
            time.sleep(pause)
    p.stdin.close()
    rc = p.wait(timeout=30)
    sys.exit(rc)

if __name__ == '__main__':
    main()
