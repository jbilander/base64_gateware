#!/bin/sh
# check_diag.sh -- validate the DiagArea header in a built turbomem .mem
#
# WHY THIS EXISTS
#
# The failure it catches is silent. A DiagArea with no boot-time bit in
# da_Config, or with a zero da_BootPoint, is never copied to RAM by
# expansion.library, so DiagPoint is never called -- and the board still
# enumerates, still answers its window, and still appears in ShowConfig.
# Stage 1 of the bring-up plan passes and tells you nothing. That cost a
# hardware round trip once; it should not cost a second.
#
#   sh check_diag.sh build-rom/turbomem.mem
#
# Exit 0 if the image will actually be copied and called, 1 otherwise.

set -u
mem=${1:-}
[ -n "$mem" ] || { echo "usage: check_diag.sh <turbomem.mem>" >&2; exit 2; }
[ -r "$mem" ] || { echo "check_diag: cannot read $mem" >&2; exit 2; }

fail=0
warn=0
note() { printf '  %-34s %s\n' "$1" "$2"; }
bad()  { printf '  *** %s\n' "$1"; fail=$((fail+1)); }
soft() { printf '  --- %s\n' "$1"; warn=$((warn+1)); }

# ---- load the image ------------------------------------------------------
nwords=$(wc -l < "$mem" | tr -d ' ')
nbytes=$((nwords * 2))

malformed=$(grep -cvE '^[0-9a-fA-F]{4}$' "$mem" || true)
[ "$malformed" -eq 0 ] || bad "$malformed line(s) are not four hex digits"

word() { sed -n "$(($1 + 1))p" "$mem"; }
byte() {
    _o=$1
    _w=$(word $((_o / 2)))
    if [ $((_o % 2)) -eq 0 ]; then echo $(( 0x$_w >> 8 ))
    else                           echo $(( 0x$_w & 255 )); fi
}

[ "$nwords" -ge 7 ] || { echo "check_diag: image is too short to hold a DiagArea" >&2; exit 1; }

w0=$(( 0x$(word 0) ))
cfg=$((  w0 >> 8 ))
flags=$(( w0 & 255 ))
size=$((    0x$(word 1) ))
diagpt=$((  0x$(word 2) ))
bootpt=$((  0x$(word 3) ))
name=$((    0x$(word 4) ))
res1=$((    0x$(word 5) ))
res2=$((    0x$(word 6) ))

buswidth=$(( cfg & 0xC0 ))
boottime=$(( cfg & 0x30 ))

echo "=== DiagArea in $mem ==="
note "image"        "$nwords words, $nbytes bytes"
note "da_Config"    "$(printf '0x%02x' $cfg)"
note "da_Flags"     "$(printf '0x%02x' $flags)"
note "da_Size"      "$size"
note "da_DiagPoint" "$diagpt"
note "da_BootPoint" "$bootpt"
note "da_Name"      "$name"

echo "=== checks ==="

# ---- bus width -----------------------------------------------------------
case $buswidth in
  128) note "bus width" "DAC_WORDWIDE" ;;
   64) bad "da_Config says DAC_BYTEWIDE - 'will not work under V34 Kickstart', and V34 is 1.3" ;;
    0) bad "da_Config says DAC_NIBBLEWIDE - this image is not nibble-spread, the copy would be garbage" ;;
    *) bad "da_Config bus width is 0xC0, which is not a defined encoding" ;;
esac

# ---- boot time: the one that silently does nothing ------------------------
case $boottime in
   16) note "boot time" "DAC_CONFIGTIME" ;;
   32) note "boot time" "DAC_BINDTIME" ;;
    0) bad "da_Config boot-time field is DAC_NEVER - expansion.library will NOT copy the diag area, so DiagPoint is NEVER called. The board will still enumerate and still appear in ShowConfig. Set DAC_CONFIGTIME (0x10)." ;;
    *) bad "da_Config boot-time field is 0x30, which is not a defined encoding" ;;
esac

# ---- da_BootPoint: must be non-NULL or no copy happens -------------------
if [ "$bootpt" -eq 0 ]; then
    bad "da_BootPoint is zero - RKM: 'the da_BootPoint offset must be non-NULL, or else no copy will occur'. No copy means no DiagPoint call."
else
    [ $((bootpt % 2)) -eq 0 ] || bad "da_BootPoint $bootpt is odd - the 68000 will address-error on entry"
    [ "$bootpt" -lt "$size" ] || bad "da_BootPoint $bootpt is outside the copied area (da_Size $size)"
fi

# ---- da_DiagPoint --------------------------------------------------------
if [ "$diagpt" -eq 0 ]; then
    bad "da_DiagPoint is zero - nothing will be called even if the copy happens"
else
    [ $((diagpt % 2)) -eq 0 ] || bad "da_DiagPoint $diagpt is odd - the 68000 will address-error on entry"
    [ "$diagpt" -lt "$size" ] || bad "da_DiagPoint $diagpt is outside the copied area (da_Size $size)"
fi

# ---- size ----------------------------------------------------------------
if [ "$size" -gt "$nbytes" ]; then
    bad "da_Size $size exceeds the image ($nbytes bytes) - the copy would read past the ROM"
fi
if [ $((size % 2)) -ne 0 ]; then
    soft "da_Size $size is odd. The copy is wordwise; a (size >> 1) loop drops the last byte, and the last byte here is the NUL terminating the name string exec keeps forever. turbomem.ld should be rounding this up."
fi

# ---- da_Name: exec stores this pointer, it does not copy the string ------
if [ "$name" -eq 0 ]; then
    soft "da_Name is zero - legal, but the board will have no identifier"
elif [ "$name" -ge "$size" ]; then
    bad "da_Name $name is outside the copied area (da_Size $size)"
else
    i=$name; term=-1
    while [ "$i" -lt "$size" ] && [ "$i" -lt "$nbytes" ]; do
        if [ "$(byte $i)" -eq 0 ]; then term=$i; break; fi
        i=$((i + 1))
    done
    if [ "$term" -lt 0 ]; then
        bad "the string at da_Name is not NUL-terminated inside the copied area - AddMemList stores this pointer and anything printing the memory list will run off the end"
    else
        s=""; i=$name
        while [ "$i" -lt "$term" ]; do
            s="$s$(printf "\\$(printf '%03o' "$(byte $i)")")"
            i=$((i + 1))
        done
        note "name string" "\"$s\" (NUL at $term)"
    fi
fi

# ---- reserved ------------------------------------------------------------
{ [ "$res1" -eq 0 ] && [ "$res2" -eq 0 ]; } || \
    bad "da_Reserved01/02 must be zero, got $res1 / $res2"

# ---- romtag scan ---------------------------------------------------------
# With a boot-time bit set, the system searches the copied image for a
# Resident structure at ROMTAG INIT time. Nothing here should look like one.
if grep -qi '^4afc$' "$mem"; then
    soft "the image contains \$4AFC (RTC_MATCHWORD). With DAC_CONFIGTIME the system scans the copy for a Resident structure - make sure this is deliberate."
else
    note "romtag matchword" "none, as expected"
fi

echo "=== $fail error(s), $warn warning(s) ==="
[ "$fail" -eq 0 ] || { echo "*** this image will not do what you think ***"; exit 1; }
echo "OK - this image will be copied and DiagPoint will be called"
exit 0
