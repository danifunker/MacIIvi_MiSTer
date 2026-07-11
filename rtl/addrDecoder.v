/*
    Macintosh IIvi Memory Map (VASP System ASIC)
    Based on MAME vasp.cpp and maciivx.cpp — see docs/VASP_RETARGET.md.

    Full 32-bit decode (VASP machines are 32-bit clean; 24-bit compatibility
    mode is implemented by the OS via the 68030 PMMU, not by hardware).

    ($00000000 - ram_size-1) RAM, contiguous
        At boot, ROM is overlaid here (reads) until first ROM-region read.
        MAME model: one contiguous block installed at 0; no V8-style
        SIMM/motherboard config-register banking (vasp.cpp rom_switch_r /
        set_ram_info). Holes above ram_size return open-bus $FFFF.

    ($40000000 - $4FFFFFFF) ROM 1MB, mirrored every 1MB
        A read here disables the overlay.

    ($50000000 - $50FFFFFF) I/O block, mirrored every 1MB (mirror $00F00000)
        +$00000  VIA1        (upper byte, $200 stride)
        +$04000  SCC
        +$06000  SCSI pseudo-DMA
        +$10000  SCSI (NCR5380) PIO
        +$12000  SCSI pseudo-DMA (mirror)
        +$14000  ASC (V8/EASC type)
        +$16000  SWIM
        +$24000  VDAC/CLUT (in VASP; same interface as the LC's Ariel)
        +$26000  PseudoVIA (base-RBV variant)

    ($5FFFFFFC) box-ID longword: $A55A2016 (Mac IIvi)

    ($60000000 - $6FFFFFFF) onboard-video VRAM, 1MB window mirrored
        (512KB real VRAM; MAME backs the full 1MB window)

    ($C0000000 - $EFFFFFFF) NuBus super-slot space  ($C/$D/$E usable)
    ($F9000000 - $FEFFFFFF) NuBus slot space        ($FC/$FD/$FE usable)
        Slot decode outputs cover $C-$E only (the IIvi's three slots);
        everything else in these ranges is empty space. Until the NuBus
        arbiter is wired, the top level answers slot space with open-bus
        $FFFF (lbmactwo empty-slot convention).

    Everything else: unmapped, open-bus $FFFF (MAME does not bus-error
    unmapped space on these machines; the ROM's RAM/slot probes rely on
    pattern mismatch, not BERR, except FC=7 CPU-space — handled in the top).
*/

module addrDecoder(
    input [31:0] address,
    input _cpuAS,
    input _cpuRW,
    input memoryOverlayOn,
    input [25:0] ram_size_bytes,   // contiguous RAM size (4/8/20/36 MB)

    output reg selectRAM,
    output reg selectROM,
    output reg selectSCSI,
    output reg selectSCSIDMA,   // SCSI pseudo-DMA window ($6000/$12000)
    output reg selectSCC,
    output reg selectIWM,
    output reg selectASC,
    output reg selectVIA,

    // VASP-internal blocks
    output reg selectVDAC,       // was Ariel on the LC — same address/interface
    output reg selectPseudoVIA,
    output reg selectVRAM,
    output reg selectBoxID,      // $5FFFFFFC machine-ID longword

    // NuBus (wired in the NuBus integration step)
    output reg selectSuperSlot,  // $C0000000-$EFFFFFFF ($C/$D/$E)
    output reg selectSlot,       // $FC000000-$FEFFFFFF ($C/$D/$E)
    output reg [1:0] slotNum,    // 0=$C 1=$D 2=$E (valid when a slot select is high)

    output reg selectUnmapped
);

    // RAM: contiguous block at 0 (36MB max < 2^26)
    wire in_ram = (address[31:26] == 6'b000000) && (address[25:0] < ram_size_bytes);
    // RAM address space (where RAM/overlay/holes live): $00000000-$3FFFFFFF
    wire ram_space = (address[31:30] == 2'b00);

    always @(*) begin
        selectRAM = 0;
        selectROM = 0;
        selectSCSI = 0;
        selectSCSIDMA = 0;
        selectSCC = 0;
        selectIWM = 0;
        selectASC = 0;
        selectVIA = 0;
        selectVDAC = 0;
        selectPseudoVIA = 0;
        selectVRAM = 0;
        selectBoxID = 0;
        selectSuperSlot = 0;
        selectSlot = 0;
        slotNum = 2'd0;
        selectUnmapped = 0;

        if (!_cpuAS) begin
            // --- RAM space ($00000000-$3FFFFFFF) ---
            if (ram_space) begin
                if (memoryOverlayOn && _cpuRW) begin
                    // Overlay active: ROM appears at $0 for READS
                    selectROM = 1;
                end else if (in_ram) begin
                    selectRAM = 1;
                end else begin
                    selectUnmapped = 1;  // open-bus $FFFF ends the ROM's RAM probe
                end
            end

            // --- ROM ($40000000-$4FFFFFFF, 1MB mirrored) ---
            else if (address[31:28] == 4'h4) begin
                selectROM = 1;
            end

            // --- VASP I/O ($50xxxxxx, 1MB block mirrored) ---
            else if (address[31:24] == 8'h50) begin
                casez (address[19:12])
                    // VIA1: +$00000-$01FFF
                    8'b0000_000?: selectVIA = 1;

                    // SCC: +$04000-$05FFF
                    8'b0000_010?: selectSCC = 1;

                    // SCSI pseudo-DMA: +$06000-$07FFF
                    8'b0000_011?: begin selectSCSI = 1; selectSCSIDMA = 1; end

                    // SCSI (NCR5380) PIO: +$10000-$11FFF
                    8'b0001_000?: selectSCSI = 1;

                    // SCSI pseudo-DMA mirror: +$12000-$13FFF
                    8'b0001_001?: begin selectSCSI = 1; selectSCSIDMA = 1; end

                    // ASC: +$14000-$15FFF
                    8'b0001_010?: selectASC = 1;

                    // SWIM: +$16000-$17FFF
                    8'b0001_011?: selectIWM = 1;

                    // VDAC/CLUT: +$24000-$25FFF
                    8'b0010_010?: selectVDAC = 1;

                    // PseudoVIA: +$26000-$27FFF
                    8'b0010_011?: selectPseudoVIA = 1;

                    default: selectUnmapped = 1;
                endcase
            end

            // --- box ID: $5FFFFFFC longword reads $A55A2016 ---
            else if (address[31:2] == 30'h17FFFFFF) begin
                selectBoxID = 1;
            end

            // --- onboard-video VRAM ($60000000-$6FFFFFFF, 1MB mirrored) ---
            else if (address[31:28] == 4'h6) begin
                selectVRAM = 1;
            end

            // --- NuBus super-slot space: $C0/$D0/$E0000000 (256MB each) ---
            else if (address[31:28] >= 4'hC && address[31:28] <= 4'hE) begin
                selectSuperSlot = 1;
                slotNum = address[29:28];  // $C->0 $D->1 $E->2
            end

            // --- NuBus slot space: $FC/$FD/$FE000000 (16MB each) ---
            else if (address[31:24] >= 8'hFC && address[31:24] <= 8'hFE) begin
                selectSlot = 1;
                slotNum = address[25:24];  // $FC->0 $FD->1 $FE->2
            end

            // --- everything else: unmapped (open-bus $FFFF) ---
            else begin
                selectUnmapped = 1;
            end
        end
    end
endmodule
