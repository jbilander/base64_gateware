/* maprom.c -- fill the Base64 mapROM shadow and switch Kickstart over to it.
 *
 * Kickstart lives on the motherboard and answers at 7 MHz with a wait state,
 * while the core runs at 42.5 MHz. Most of what the OS executes is ROM code,
 * so serving it from SDRAM on-chip is the largest speedup left in the design.
 *
 * The gateware gives us two bits in the turbomem board's window at +$F008,
 * both cleared at reset, both requiring $5A in the high byte so a stray write
 * cannot arm them:
 *
 *   $5A01  LOAD    writes to $F80000-$FFFFFF and $E00000-$E7FFFF land in the
 *                  SDRAM shadow instead of nowhere. Reads are unaffected, so
 *                  they still come from the real ROM. This is the only way in:
 *                  the shadow is not reachable from any CPU window.
 *   $5A02  ACTIVE  reads from those ranges come from the shadow.
 *   $5A00  OFF
 *
 * So the copy is an ordinary move loop with both pointers at $F80000: the read
 * fetches real ROM, the write lands in the shadow.
 *
 *   maprom            copy and switch over
 *   maprom OFF        switch back to the motherboard ROM
 *   maprom STATUS     report without changing anything
 *
 * THE DANGEROUS MOMENT is setting ACTIVE. From that instruction onwards every
 * ROM fetch comes from the shadow, so if the shadow is wrong the next OS call
 * executes garbage and the machine is gone with no way to report why. The
 * verify below therefore runs with interrupts disabled and calls NOTHING in
 * ROM between arming and checking -- see switch_and_verify(). It can always
 * put the machine back the way it was.
 *
 * NOT COMPILE-TESTED -- there is no m68k toolchain on the machine this was
 * written on. It follows cfgdump.c, which does build.
 *
 * Build:  make maprom
 */

#include <exec/types.h>
#include <exec/execbase.h>
#include <libraries/configvars.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <proto/expansion.h>
#include <stdarg.h>
#include <ks13_compat.h>

struct ExecBase      *SysBase;
struct DosLibrary    *DOSBase;
struct ExpansionBase *ExpansionBase;

#define MFG_ID      5194
#define PROD_TURBO  14              /* the AutoConfig ROM board */

#define REG_MAGIC   0xF000          /* $544D if the status window is present */
#define REG_CTRL    0xF008
#define MAGIC       0x544D

#define MR_OFF      0x5A00
#define MR_LOAD     0x5A01
#define MR_ACTIVE   0x5A02

/* The two shadowed banks. Kept in this order because the boot bank is the one
 * that matters; the extended bank is optional and often absent. */
#define BOOT_BASE   0x00F80000UL
#define EXT_BASE    0x00E00000UL
#define BANK_SIZE   0x00080000UL    /* 512 KB each */

/* BOTH BANKS ARE ALWAYS COPIED, VERBATIM, WITH NO INSPECTION.
 *
 * The first version of this tool tried to work out whether each bank held a
 * real ROM and skipped the ones it thought were empty. That was wrong twice
 * over and it crashed a machine:
 *
 *   - The gateware has ONE active bit covering both ranges. Skip a bank and
 *     its reads are still redirected, to shadow SDRAM nobody filled. On a
 *     1 MB Kickstart that is live code, and the CPU executes noise: Software
 *     Failure #8000000A, the line-1010 exception.
 *   - It assumed 512 KB at $F80000. Kickstart 1.3 is 256 KB at $FC0000, so
 *     the signature was never where it was being looked for.
 *
 * Copying verbatim removes the whole question. Whatever the motherboard
 * returns for an address - real ROM, an alias of another bank because the
 * chip has no A19 to tell them apart, or nothing at all - is reproduced
 * exactly, so switching over cannot change what the machine sees. There is
 * nothing left to detect and nothing left to get wrong.
 *
 * The signatures below are printed for information only. They gate nothing.
 */
#define ROMID_256K  0x11114EF9UL
#define ROMID_512K  0x11144EF9UL

#define put_lit(s)  Write(Output(), (CONST_APTR)(s), (LONG)(sizeof(s) - 1))

static void putch(UBYTE c asm("d0"), APTR data asm("a3"))
{
    char **pp = (char **)data;
    *(*pp)++ = (char)c;
}

static void cprintf(CONST_STRPTR fmt, ...)
{
    char    buf[200];
    char   *p = buf;
    LONG    n;
    va_list ap;

    va_start(ap, fmt);
    RawDoFmt((CONST_STRPTR)fmt, ap, (void (*)())putch, &p);
    va_end(ap);

    n = (LONG)(p - buf) - 1;
    if (n > 0)
        Write(Output(), (CONST_APTR)buf, n);
}

/* ------------------------------------------------------------------------ */

static volatile UWORD *ctrl_reg;    /* the mapROM control register */

/* Find the turbomem board and check it really carries a status window.
 * Returns 0 on success. */
static int find_board(void)
{
    struct ConfigDev *cd = NULL;
    volatile UBYTE   *base;

    cd = FindConfigDev(NULL, MFG_ID, PROD_TURBO);
    if (!cd) {
        put_lit("No Base64 AutoConfig ROM board found (5194/14).\n");
        return 1;
    }

    base = (volatile UBYTE *)cd->cd_BoardAddr;

    /* Read the magic as two bytes: the window is word aligned here, but the
     * habit is worth keeping -- cfgdump took an address error once by
     * assuming otherwise on a board whose diag area is byte wide. */
    if ((UWORD)((base[REG_MAGIC] << 8) | base[REG_MAGIC + 1]) != MAGIC) {
        put_lit("Board found, but no status window - gateware is too old.\n");
        return 1;
    }

    ctrl_reg = (volatile UWORD *)(base + REG_CTRL);
    cprintf((CONST_STRPTR)"Base64 AutoConfig ROM board at $%08lx\n",
            (ULONG)cd->cd_BoardAddr);
    return 0;
}

static UWORD ctrl_read(void)   { return *ctrl_reg & 0x0003; }
static void  ctrl_write(UWORD v) { *ctrl_reg = v; }

/* Say what a bank looks like. Informational only - nothing branches on it. */
static void describe(CONST_STRPTR name, ULONG base)
{
    ULONG id = *(volatile ULONG *)base;

    cprintf((CONST_STRPTR)"  %s $%06lx  first longword $%08lx  %s\n",
            name, base, id,
            (CONST_STRPTR)(id == ROMID_512K ? "512 KB Kickstart signature" :
                           id == ROMID_256K ? "256 KB Kickstart signature" :
                                              "no Kickstart signature"));
}

/* Checksum a bank. Deliberately order dependent - a plain sum of longwords
 * would not notice a copy that landed in the wrong order, which is exactly
 * the sort of address-mapping mistake this is here to catch. */
static ULONG sum_bank(ULONG base)
{
    volatile ULONG *p = (volatile ULONG *)base;
    ULONG i, s = 0;

    for (i = 0; i < BANK_SIZE / 4; i++)
        s = ((s << 1) | (s >> 31)) + p[i];
    return s;
}

static void copy_bank(ULONG base)
{
    volatile ULONG *src = (volatile ULONG *)base;
    ULONG          *dst = (ULONG *)base;
    ULONG i;

    /* LOAD is set, so the read goes to the motherboard ROM and the write goes
     * to the shadow, even though both use the same address. */
    for (i = 0; i < BANK_SIZE / 4; i++)
        dst[i] = src[i];
}

/* ------------------------------------------------------------------------
 * The switchover.
 *
 * Between arming ACTIVE and deciding whether to keep it, this function must
 * not call anything that lives in ROM -- which is nearly everything. So:
 * Disable() first, then only inline work on the shadow, then either keep it
 * or put it back before Enable().
 *
 * sum_bank and ctrl_write are in this file, so they are in RAM with the rest
 * of the tool. Nothing here touches the OS.
 *
 * Returns 0 if the shadow verified and ACTIVE is left set.
 * ---------------------------------------------------------------------- */
static int switch_and_verify(ULONG boot_sum, ULONG ext_sum)
{
    ULONG got_boot, got_ext;
    int   bad = 0;

    Disable();

    ctrl_write(MR_ACTIVE);          /* reads now come from the shadow */

    got_boot = sum_bank(BOOT_BASE);
    got_ext  = sum_bank(EXT_BASE);

    if (got_boot != boot_sum) bad |= 1;
    if (got_ext  != ext_sum)  bad |= 2;

    if (bad)
        ctrl_write(MR_OFF);         /* back to the motherboard, no harm done */

    Enable();
    return bad;
}

/* ------------------------------------------------------------------------ */

static void report(void)
{
    UWORD c = ctrl_read();

    cprintf((CONST_STRPTR)"  control $%04lx  load %s  active %s\n",
            (ULONG)c,
            (CONST_STRPTR)((c & 1) ? "on " : "off"),
            (CONST_STRPTR)((c & 2) ? "on " : "off"));

    if (c & 2)
        put_lit("  Kickstart is being served from SDRAM.\n");
    else
        put_lit("  Kickstart is being served from the motherboard.\n");
}

int _start(void) __attribute__((section(".text.entry")));

int _start(void)
{
    struct Process *proc;
    UBYTE          *cmd;
    ULONG           boot_sum, ext_sum;
    int             bad, rc = 0;

    asm volatile ("move.l 4.w,%0" : "=r"(SysBase));

    DOSBase = (struct DosLibrary *)OpenLibrary((CONST_STRPTR)"dos.library", 0);
    if (!DOSBase)
        return 20;

    ExpansionBase = (struct ExpansionBase *)
        OpenLibrary((CONST_STRPTR)"expansion.library", 0);
    if (!ExpansionBase) {
        put_lit("cannot open expansion.library\n");
        CloseLibrary((struct Library *)DOSBase);
        return 20;
    }

    if (find_board()) {
        rc = 20;
        goto out;
    }

    /* Argument handling, kept deliberately crude: look at the first character
     * of the command line only. O -> OFF, S -> STATUS, anything else -> go. */
    proc = (struct Process *)FindTask(NULL);
    cmd  = (UBYTE *)proc->pr_Arguments;

    while (*cmd == ' ' || *cmd == '\t') cmd++;

    if (*cmd == 'S' || *cmd == 's') {
        report();
        goto out;
    }

    if (*cmd == 'O' || *cmd == 'o') {
        ctrl_write(MR_OFF);
        put_lit("mapROM disabled.\n");
        report();
        goto out;
    }

    if (ctrl_read() & 2) {
        put_lit("mapROM is already active. Use OFF first if you want to redo it.\n");
        goto out;
    }

    /* ---- what is out there, for the record ---- */
    put_lit("Shadowing 1 MB, both banks, exactly as the motherboard reads:\n");
    describe((CONST_STRPTR)"boot", BOOT_BASE);
    describe((CONST_STRPTR)"ext ", EXT_BASE);

    /* ---- checksum the real ROM before we touch anything ---- */
    boot_sum = sum_bank(BOOT_BASE);
    ext_sum  = sum_bank(EXT_BASE);

    /* ---- fill the shadow ---- */
    put_lit("Copying ... ");
    ctrl_write(MR_LOAD);
    copy_bank(BOOT_BASE);
    copy_bank(EXT_BASE);
    ctrl_write(MR_OFF);             /* close the write window again */
    put_lit("done.\n");

    /* ---- arm and check ---- */
    put_lit("Switching over ... ");
    bad = switch_and_verify(boot_sum, ext_sum);
    if (bad) {
        put_lit("FAILED.\n");
        cprintf((CONST_STRPTR)"  %s bank did not read back correctly.\n",
                (CONST_STRPTR)((bad & 3) == 3 ? "Both the boot and the ext" :
                               (bad & 1)      ? "The boot" : "The ext"));
        put_lit("mapROM has been turned back off; the machine is running\n"
                "from the motherboard ROM exactly as before.\n");
        rc = 20;
        goto out;
    }
    put_lit("ok.\n");
    report();

out:
    CloseLibrary((struct Library *)ExpansionBase);
    CloseLibrary((struct Library *)DOSBase);
    return rc;
}
