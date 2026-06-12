/* keytest_main.c — keyboard diagnostic preboot bench.
 *
 * Polls KeyMap at $0174 (16 bytes, one bit per Mac virtual keycode)
 * and displays:
 *
 *   - the raw 16 bytes in hex (so we can see if the ROM is updating
 *     KeyMap at all — if every byte stays at $00 while you mash the
 *     keyboard, the ADB completion routine isn't running pre-System
 *     and we need a different approach)
 *   - the list of currently-held keycodes
 *   - the most recent press / release events
 *
 * No exit condition — runs forever. Power-cycle to leave. */

#include "bench_types.h"
#include "eject.h"

extern void paint_string(u32 row, u32 col_byte, const char *s, u32 max_chars);

/* Boot handoff drive number, loaded by payload_entry.s. Used to eject
 * the floppy when the operator presses Return. */
extern i16 g_handoff_drive;

/* KeyMap bit test for a given Mac virtual keycode. */
#define KEY_DOWN(map, kc) ((map)[(kc) >> 3] & (u8)(1u << ((kc) & 7)))
#define KC_RETURN 0x24

#define LINE(n) ((n) * 12u)

/* KeyMap low-mem global: 16 bytes at $0174 = 128 bits, one per Mac
 * virtual keycode. byte = keycode/8, bit = keycode%8. */
#define KEYMAP_BASE 0x00000174u

static const char hex[16] = "0123456789ABCDEF";

/* Mac virtual keycode -> single-char label for the most common keys.
 * Returns '?' for unmapped keys (we still show the decimal keycode
 * elsewhere). Keycodes from Inside Macintosh: Toolbox Essentials. */
static char keycode_label(u8 kc)
{
    switch (kc) {
        case 0x00: return 'A';
        case 0x0B: return 'B';
        case 0x08: return 'C';
        case 0x02: return 'D';
        case 0x0E: return 'E';
        case 0x03: return 'F';
        case 0x05: return 'G';
        case 0x04: return 'H';
        case 0x22: return 'I';
        case 0x26: return 'J';
        case 0x28: return 'K';
        case 0x25: return 'L';
        case 0x2E: return 'M';
        case 0x2D: return 'N';
        case 0x1F: return 'O';
        case 0x23: return 'P';
        case 0x0C: return 'Q';
        case 0x0F: return 'R';
        case 0x01: return 'S';
        case 0x11: return 'T';
        case 0x20: return 'U';
        case 0x09: return 'V';
        case 0x0D: return 'W';
        case 0x07: return 'X';
        case 0x10: return 'Y';
        case 0x06: return 'Z';
        case 0x12: return '1';
        case 0x13: return '2';
        case 0x14: return '3';
        case 0x15: return '4';
        case 0x17: return '5';
        case 0x16: return '6';
        case 0x1A: return '7';
        case 0x1C: return '8';
        case 0x19: return '9';
        case 0x1D: return '0';
        case 0x31: return ' ';   /* Space */
        case 0x24: return '\r';  /* Return */
        case 0x33: return '<';   /* Backspace */
        case 0x35: return '!';   /* Esc -- shown as ! */
        default:   return '?';
    }
}

static void put_hex8(char *dst, u8 v)
{
    dst[0] = hex[(v >> 4) & 0xF];
    dst[1] = hex[ v       & 0xF];
}

static void put_dec3(char *dst, u8 v)
{
    dst[0] = (v >= 100) ? ('0' + (v / 100) % 10) : ' ';
    dst[1] = (v >= 10)  ? ('0' + (v / 10)  % 10) : ' ';
    dst[2] =              ('0' +  v        % 10);
}

/* Snapshot KeyMap into out[16]. Volatile reads so the compiler
 * doesn't elide them on the (mistaken) assumption that the underlying
 * memory never changes. */
static void read_keymap(u8 out[16])
{
    u32 i;
    for (i = 0; i < 16; i++) out[i] = *(volatile u8 *)(KEYMAP_BASE + i);
}

void bench_main(void)
{
    u8 prev[16] = {0};
    u8 curr[16];
    u8 last_press = 0xFF;
    u8 last_release = 0xFF;

    paint_string(LINE(0),  1, "KEYTEST: press keys (ADB keyboard diagnostic)", 45);
    paint_string(LINE(2),  1, "KeyMap raw (hex, $0174..$0183):", 31);
    paint_string(LINE(5),  1, "DOWN now:", 9);
    paint_string(LINE(7),  1, "Last PRESS:   kc=    ch=", 24);
    paint_string(LINE(8),  1, "Last RELEASE: kc=    ch=", 24);
    paint_string(LINE(10), 1, "If KeyMap never changes, ROM isn't updating it pre-System.", 58);
    paint_string(LINE(11), 1, "Press RETURN to eject the floppy + halt.", 40);

    for (;;) {
        read_keymap(curr);

        /* Paint raw bytes across two rows of 8 bytes each. */
        {
            char row1[24];   /* "00 00 00 00 00 00 00 00 " */
            char row2[24];
            u32 i, p1 = 0, p2 = 0;
            for (i = 0; i < 8; i++) {
                put_hex8(&row1[p1], curr[i]);     p1 += 2; row1[p1++] = ' ';
                put_hex8(&row2[p2], curr[i + 8]); p2 += 2; row2[p2++] = ' ';
            }
            paint_string(LINE(3), 1, row1, 24);
            paint_string(LINE(4), 1, row2, 24);
        }

        /* List currently-held keycodes as "DDD/c " entries on LINE 5
         * starting after the "DOWN now:" label (col 11). Cap at 6
         * entries to fit in ~36 chars. */
        {
            char list[48];
            u32 lp = 0, n_down = 0;
            u32 i;
            for (i = 0; i < sizeof(list); i++) list[i] = ' ';
            for (i = 0; i < 128 && n_down < 6; i++) {
                u8 byte_idx = i >> 3;
                u8 bit_mask = (u8)(1u << (i & 7));
                if (curr[byte_idx] & bit_mask) {
                    if (lp + 6 > sizeof(list)) break;
                    put_dec3(&list[lp], (u8)i); lp += 3;
                    list[lp++] = '/';
                    list[lp++] = keycode_label((u8)i);
                    list[lp++] = ' ';
                    n_down++;
                }
            }
            if (n_down == 0) {
                list[0] = '('; list[1] = 'n'; list[2] = 'o'; list[3] = 'n';
                list[4] = 'e'; list[5] = ')';
                lp = 6;
            }
            paint_string(LINE(5), 11, list, (u32)(lp > 36 ? 36 : lp));
        }

        /* Edge-detect press / release transitions. Compare curr vs prev
         * bit by bit; for each bit that flipped, update last_press or
         * last_release accordingly. We only track the highest-keycode
         * transition per frame to keep things simple. */
        {
            u32 i;
            for (i = 0; i < 16; i++) {
                u8 diff = (u8)(curr[i] ^ prev[i]);
                u8 b;
                if (!diff) continue;
                for (b = 0; b < 8; b++) {
                    if (!(diff & (1u << b))) continue;
                    u8 kc = (u8)((i << 3) | b);
                    if (curr[i] & (1u << b)) last_press = kc;
                    else                     last_release = kc;
                }
            }
        }

        /* Repaint the press/release cells. "kc=" at col 18, "ch=" at col 26. */
        {
            char buf[5];
            if (last_press != 0xFF) {
                put_dec3(buf, last_press);
                buf[3] = ' '; buf[4] = ' ';
                paint_string(LINE(7), 18, buf, 5);
                char ch[1] = { keycode_label(last_press) };
                paint_string(LINE(7), 26, ch, 1);
            }
            if (last_release != 0xFF) {
                put_dec3(buf, last_release);
                buf[3] = ' '; buf[4] = ' ';
                paint_string(LINE(8), 18, buf, 5);
                char ch[1] = { keycode_label(last_release) };
                paint_string(LINE(8), 26, ch, 1);
            }
        }

        /* Save current state for next-frame edge detection. */
        {
            u32 i;
            for (i = 0; i < 16; i++) prev[i] = curr[i];
        }

        /* RETURN ejects the floppy and halts — lets us verify eject
         * works via the keyboard we just validated. Show the drive
         * number we pass and the .Sony Control ioResult so we can tell
         * a real eject from a driver rejection (e.g. wrong drive #). */
        if (KEY_DOWN(curr, KC_RETURN)) {
            paint_string(LINE(11), 1, "Ejecting...                             ", 40);
            i16 drv = g_handoff_drive;
            i16 res = eject_floppy(drv);

            char msg[40];
            u32 m;
            for (m = 0; m < sizeof(msg); m++) msg[m] = ' ';
            /* "eject drv=DDD res=±DDDDD" */
            const char *p = "eject drv=";
            for (m = 0; p[m]; m++) msg[m] = p[m];
            put_dec3(&msg[m], (u8)drv); m += 3;
            msg[m++] = ' '; msg[m++] = 'r'; msg[m++] = 'e'; msg[m++] = 's';
            msg[m++] = '=';
            {
                i32 v = res;
                if (v < 0) { msg[m++] = '-'; v = -v; }
                u32 div[5] = { 10000, 1000, 100, 10, 1 };
                u32 d, started = 0;
                for (d = 0; d < 5; d++) {
                    u32 digit = ((u32)v / div[d]) % 10;
                    if (digit || started || d == 4) { msg[m++] = (char)('0' + digit); started = 1; }
                }
            }
            paint_string(LINE(11), 1, msg, m);
            for (;;) { asm volatile (""); }
        }
    }
}
