#!/bin/bash
# =============================================================================
# reboot-io-summary.sh
#
# PURPOSE
#   Build a reboot timeline and accumulate IO metrics across all reboots,
#   then print a summary, WITHOUT touching the stressed system.
#   Output sections:
#     - reboot timeline
#     - accumulated metrics, broken down by reboot interval (boot window)
#     - per-boot headline (read/write GiB, transactions, %iowait, %util)
#     - grand totals: read bytes, write bytes, transactions (all boots)
#   Constraints:
#     * no daemon, no cron, no timers
#     * no /proc reads by this script
#     * no nice/ionice, no sysfs/tunable changes
#     * runs as a NON-root user
#
# DATA SOURCES (both are existing, already-written history)
#   1. journalctl --list-boots output, stored in a text file
#      (generated once by a user who can read the journal)
#   2. sysstat history files (/var/log/sa/saDD or saYYYYMMDD) read with
#      `sar -f`. sysstat must already have been collecting.
#
# USAGE
#   Step 1 - from a session that can read the journal (once):
#       journalctl --no-pager --list-boots > /tmp/boots.txt
#       chmod 644 /tmp/boots.txt
#
#   Step 2 - as the non-root user:
#       ./reboot-io-summary.sh /tmp/boots.txt               # no per-disk rows
#       ./reboot-io-summary.sh -d sda,sdb /tmp/boots.txt    # only sda and sdb
#       ./reboot-io-summary.sh -d ALL /tmp/boots.txt        # every device
#       ./reboot-io-summary.sh -n 5 -d sda /tmp/boots.txt   # last 5 boots only
#
# OPTIONS
#   -d DEVICES  disks to show in the accumulated section: comma or space
#               separated names as sar prints them (sda, sdb, nvme0n1,
#               ubuntu--vg-ubuntu--lv ...), or ALL for every device.
#               DEFAULT: none - no individual device rows are printed.
#               (Also settable via the DEVICES environment variable.)
#   -n N        only process the N most recent boots (same as LAST_BOOTS)
#   -h          show usage
#
# ENVIRONMENT VARIABLES
#   BOOTS_FILE  path to the saved --list-boots output (or pass as $1)
#   LAST_BOOTS  only process the N most recent boots (lighter on the system)
#   SA_DIRS     space-separated dirs holding sysstat files
#               (default: "/var/log/sa /var/log/sysstat")
#   MAXGAP      ignore sample gaps longer than this many seconds, so crashes
#               and restarts are never counted as activity (default 1800)
#
# FILES WRITTEN
#   None, except: if no boots file is given, one mktemp file is created for
#   journalctl output and deleted on exit.
# =============================================================================

# Fixed locale and ISO timestamps from sar make parsing predictable.
export LC_ALL=C S_TIME_FORMAT=ISO

SA_DIRS=${SA_DIRS:-"/var/log/sa /var/log/sysstat"}
MAXGAP=${MAXGAP:-1800}
DEVICES=${DEVICES:-}          # default: no individual device rows

usage() {
  echo "Usage: $0 [-d DEVICES|ALL] [-n N] [BOOTS_FILE]" >&2
  echo "  -d  disks to show (comma/space separated, or ALL). Default: none" >&2
  echo "  -n  only the N most recent boots" >&2
}
while getopts "d:n:h" opt; do
  case $opt in
    d) DEVICES=$OPTARG ;;
    n) LAST_BOOTS=$OPTARG ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
shift $((OPTIND-1))           # what remains: optional BOOTS_FILE
DEVICES=${DEVICES//,/ }       # accept "sda,sdb" as well as "sda sdb"

# -----------------------------------------------------------------------------
# sar output parser (awk program, kept in a variable and passed to each awk).
#
# Input : output of one `sar <opts> -f <file>` run.
# Output: tab-separated lines
#           boot_idx  key  metric  integral  seconds_covered  max_value
#         where integral = sum(rate_value * seconds_between_samples), so
#         per-second rates (tps, kB/s, ...) become totals, and percentages
#         become time-weighted sums (divided later to give averages).
# -----------------------------------------------------------------------------
PARSE=$(cat <<'EOF'
function t2s(t,  a){ split(t,a,":"); return a[1]*3600+a[2]*60+a[3] }

# First line of a sar file carries its date. If it is not the day we asked
# for (e.g. saDD file left over from another month), discard the whole file.
NR==1 { for(i=1;i<=NF;i++)
          if($i ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && $i!=day) bad=1 }
bad { exit }

# Only lines starting with HH:MM:SS are data/header lines ("Average:" skipped).
$1 ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ {

  # A restart marker means counters reset: forget previous timestamps.
  if ($0 ~ /LINUX RESTART/) { delete pt; next }

  # Header line? The "key" column (DEV for -d, CPU for -u) is NOT always in the
  # same place: older sysstat puts it second ("time DEV tps ..."), newer puts
  # DEV last ("time tps ... %util DEV"). So search the whole line for it.
  # -b has no key column: its header is "time tps rtps ...".
  kc = 0; isH = 0
  for (i=2;i<=NF;i++) if ($i=="DEV" || $i=="CPU") { kc=i; isH=1 }
  if (!isH && $2=="tps") isH=1
  if (isH) {
    keycol = kc; hdr = kc ? $kc : "B"
    delete names; for (i=2;i<=NF;i++) if (i!=kc) names[i]=$i
    seen_hdr = 1
    next
  }
  if (!seen_hdr) next
  if (hdr=="CPU" && $keycol!="all") next     # only the all-CPU aggregate

  key = keycol ? $keycol : "-"               # device/CPU name, or "-" for -b
  t = t2s($1); dt = 0
  # Interval = time since previous sample of this key, only if sane.
  if ((key in pt) && t>pt[key] && t-pt[key]<=maxgap) dt = t-pt[key]
  pt[key] = t
  if (dt==0) next                            # first sample: interval unknown

  for (i=2;i<=NF;i++) {
    if (i==keycol) continue                  # skip the name column itself
    k = key SUBSEP names[i]
    integ[k] += $i*dt; secs[k] += dt
    if(!(k in mx) || $i>mx[k]) mx[k]=$i
  }
}
END { for(k in integ){ split(k,p,SUBSEP)
        printf "%s\t%s\t%s\t%.6f\t%d\t%s\n", boot,p[1],p[2],integ[k],secs[k],mx[k] } }
EOF
)

# -----------------------------------------------------------------------------
# find_sa DATE(YYYY-MM-DD)
#   Print the path of the sysstat file for that day, if readable.
#   Tries both naming schemes: saYYYYMMDD and saDD.
# -----------------------------------------------------------------------------
find_sa() {
  local d=$1 dir f
  for dir in $SA_DIRS; do
    for f in "$dir/sa${d//-/}" "$dir/sa${d:8:2}"; do
      [ -r "$f" ] && { echo "$f"; return; }
    done
  done
}

# -----------------------------------------------------------------------------
# run_boot IDX START_DATE START_TIME END_DATE END_TIME
#   Walk every calendar day inside one boot window, run sar on that day's file
#   restricted to the window (-s/-e), and feed it through the parser.
#   Three sar runs per day: -b (global IO), -u (CPU/iowait), -d -p (per disk).
#   (Drop "-p" below if you do not want sar reading /dev/mapper names.)
# -----------------------------------------------------------------------------
run_boot() {
  local idx=$1 sd=$2 st=$3 ed=$4 et=$5 day lo hi f opts
  day=$sd
  while :; do
    f=$(find_sa "$day")
    if [ -n "$f" ]; then
      lo=00:00:00; hi=23:59:59
      [ "$day" = "$sd" ] && lo=$st           # first day starts at boot time
      [ "$day" = "$ed" ] && hi=$et           # last day ends at shutdown time
      for opts in "-b" "-u" "-d -p"; do
        # $opts intentionally unquoted so "-d -p" splits into two args
        sar $opts -f "$f" -s "$lo" -e "$hi" 2>/dev/null |
          awk -v boot="$idx" -v day="$day" -v maxgap="$MAXGAP" "$PARSE"
      done
    fi
    [ "$day" = "$ed" ] && break
    day=$(date -d "$day + 1 day" +%F)
    [[ "$day" > "$ed" ]] && break            # safety net
  done
}

# fmt SECONDS -> "XdYYhZZm"
fmt() { local s=$1; printf '%dd%02dh%02dm' $((s/86400)) $((s%86400/3600)) $((s%3600/60)); }

# =============================================================================
# 1. REBOOT TIMELINE - read journalctl --list-boots output from a file
# =============================================================================
BOOTS_FILE=${1:-${BOOTS_FILE:-}}

if [ -z "$BOOTS_FILE" ]; then
  # No file supplied: try journalctl directly into a temp file. This only
  # works if the current user may read the journal (e.g. systemd-journal group).
  TMP=$(mktemp) || exit 1
  trap 'rm -f "$TMP"' EXIT
  journalctl --no-pager --list-boots > "$TMP" 2>/dev/null
  BOOTS_FILE=$TMP
fi
[ -r "$BOOTS_FILE" ] || { echo "Cannot read boots file: $BOOTS_FILE" >&2; exit 1; }

# Extract: index, boot id, start date/time, end date/time (first two dates on
# each line). The em dash separating first/last entry is turned into a space.
boots=$(sed 's/—/ /g' "$BOOTS_FILE" | awk '
  { n=0
    for(i=1;i<=NF;i++)
      if($i ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && n<2){
        d[n]=$i; t[n]=$(i+1); n++ }
    if(n==2) print $1, $2, d[0], t[0], d[1], t[1] }')

[ -n "$boots" ] || { echo "No boots parsed from $BOOTS_FILE (empty file, or journal not readable when it was generated)" >&2; exit 1; }

# Sort oldest -> newest by start epoch, optionally keep only the last N boots.
sorted=$(while read -r idx id sd st ed et; do
           echo "$(date -d "$sd $st" +%s) $idx $id $sd $st $ed $et"
         done <<< "$boots" | sort -n)
[ -n "${LAST_BOOTS:-}" ] && sorted=$(printf '%s\n' "$sorted" | tail -n "$LAST_BOOTS")

# =============================================================================
# 2. PRINT TIMELINE AND COLLECT sar DATA PER BOOT
# =============================================================================
echo "== Reboot timeline (journalctl) =="
printf '%-5s %-8s %-19s %-19s %-10s %s\n' IDX BOOT START END UPTIME DOWN_BEFORE

meta=""        # per-boot labels, reused in the per-boot summary
raw=""         # all parsed sar records for all boots
prev_end=""    # end of previous boot, to compute downtime

while read -r s idx id sd st ed et; do
  e=$(date -d "$ed $et" +%s)
  gap="-"; [ -n "$prev_end" ] && gap=$(fmt $((s-prev_end)))

  printf '%-5s %-8s %-19s %-19s %-10s %s\n' \
    "$idx" "${id:0:8}" "$sd $st" "$ed $et" "$(fmt $((e-s)))" "$gap"

  meta+="$idx|$sd $st|$(fmt $((e-s)))|$gap"$'\n'
  raw+="$(run_boot "$idx" "$sd" "$st" "$ed" "$et")"$'\n'
  prev_end=$e
done <<< "$sorted"

if [ -z "$(printf '%s' "$raw" | tr -d '\n')" ]; then
  echo; echo "No sar data found in: $SA_DIRS (is sysstat collecting? are files readable?)" >&2
  exit 1
fi

# =============================================================================
# 3. ACCUMULATED METRICS, BROKEN DOWN BY REBOOT INTERVAL (boot window)
#    One block of rows per boot (IDX). Per row:
#      byte-rate metrics (bread/s, bwrtn/s, rkB/s, wkB/s ...) -> total bytes
#      tps-type metrics  (tps, rtps, wtps ...)                -> total IOs
#      everything else (%util, await, %iowait ...)            -> time-weighted avg
#    KEY: "-" = whole system (sar -b), "all" = all CPUs, else a disk name.
#    bread/s and bwrtn/s are 512-byte blocks/s, so bytes = integral x 512.
# =============================================================================
if [ -z "$DEVICES" ]; then DEVNOTE="none (use -d sda,sdb or -d ALL)"; else DEVNOTE=$DEVICES; fi
echo; echo "== Accumulated per reboot interval (sar) - devices: $DEVNOTE =="
printf '%-5s %-12s %-10s %16s %-5s %12s %10s\n' IDX KEY METRIC TOTAL_OR_AVG UNIT MAX COVERED_h

printf '%s\n' "$raw" | awk -F'\t' -v devs="$DEVICES" '
  # Device filter: build the wanted set from the -d value (ALL = everything).
  BEGIN { n=split(devs,a," ")
          for(i=1;i<=n;i++){ if(toupper(a[i])=="ALL") all=1; else want[a[i]]=1 } }
  # bytes per unit for throughput metrics (0 = not a byte rate)
  function bytes(m){
    if (m ~ /^(bread|bwrtn|bdscd)\/s$/ || m ~ /sec\/s$/) return 512   # sectors
    if (m ~ /kB\/s$/) return 1024
    if (m ~ /MB\/s$/) return 1048576
    return 0 }
  NF==6 { K=$1 SUBSEP $2 SUBSEP $3; I[K]+=$4; S[K]+=$5
          if(!(K in X) || $6>X[K]) X[K]=$6 }
  END { for(K in I){ split(K,p,SUBSEP); b=p[1]; d=p[2]; m=p[3]
          # "-" (whole system) and "all" (all CPUs) always shown; any other
          # key is a disk and is shown only if selected.
          if (d!="-" && d!="all") { if (!all && !(d in want)) continue; found[d]=1 }
          if (m ~ /\/s$/ || m ~ /tps$/) {
            n=bytes(m)
            if (n>0) printf "%-5s %-12s %-10s %16.0f %-5s %12.2f %10.1f\n", b,d,m,I[K]*n,"bytes",X[K],S[K]/3600
            else     printf "%-5s %-12s %-10s %16.0f %-5s %12.2f %10.1f\n", b,d,m,I[K],"IOs",X[K],S[K]/3600
          } else     printf "%-5s %-12s %-10s %16.2f %-5s %12.2f %10.1f\n", b,d,m,I[K]/S[K],"avg",X[K],S[K]/3600 }
        for(w in want) if(!(w in found)) print "note: device not found in sar data: " w > "/dev/stderr" }' |
  sort -k1,1n -k2,2 -k3,3

# =============================================================================
# 4. PER-BOOT HEADLINE (the "reboot pattern" view)
#    Labels are passed through the environment because they contain newlines.
# =============================================================================
echo; echo "== Per boot =="
printf '%s\n' "$raw" | META="$meta" awk -F'\t' '
  NF==6 { b=$1; k=$2; m=$3
    if (k=="-"   && m=="bread/s")  R[b]+=$4          # read sectors total
    if (k=="-"   && m=="bwrtn/s")  W[b]+=$4          # written sectors total
    if (k=="-"   && m=="tps")     { T[b]+=$4; C[b]+=$5 }   # transactions, seconds covered
    if (k=="all" && m=="%iowait") { OI[b]+=$4; OS[b]+=$5 }
    if (m=="%util" && $6>U[b])     U[b]=$6           # worst disk %util
    seen[b]=1 }
  END { n=split(ENVIRON["META"],L,"\n"); last=0
        for(i=1;i<=n;i++) if(L[i]!="") last=i        # newest boot = last label
        printf "%-5s %-19s %-10s %-10s %9s %9s %12s %8s %8s %8s\n",
               "IDX","START","UPTIME","DOWN","READ_GiB","WRITE_GiB","TRANSACTIONS","%iowait","max%util","covered"
        for(i=1;i<=n;i++){ if(L[i]=="") continue
          split(L[i],f,"|"); b=f[1]
          printf "%-5s %-19s %-10s %-10s ", b,f[2],f[3],f[4]
          if (b in seen)
            printf "%9.2f %9.2f %12.0f %8.1f %8.1f %7.1fh", R[b]*512/2^30, W[b]*512/2^30, T[b],
                   (OS[b]?OI[b]/OS[b]:0), U[b], C[b]/3600
          else printf "%s", "no sar data"
          printf "%s\n", (i==last ? "  <- latest" : "") } }'

# =============================================================================
# 5. GRAND TOTALS (raw bytes and transaction count across all listed boots)
#    From sar -b (global block IO). bread/s and bwrtn/s are 512-byte blocks/s,
#    tps is transfers/s; each was integrated over time in the parser.
# =============================================================================
echo; echo "== Grand totals across listed boots (sar -b) =="
printf '%s\n' "$raw" | awk -F'\t' '
  NF==6 && $2=="-" { if($3=="bread/s") R+=$4
                     if($3=="bwrtn/s") W+=$4
                     if($3=="tps")     T+=$4 }
  END { printf "%-14s %18.0f\n", "read_bytes",   R*512
        printf "%-14s %18.0f\n", "write_bytes",  W*512
        printf "%-14s %18.0f\n", "transactions", T }'
