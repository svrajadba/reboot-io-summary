# reboot-io-summary

A read-only shell script that builds a **reboot timeline** and **accumulates IO metrics across reboots** from history the system has already recorded. It is designed for machines that are already under severe stress, so it adds almost no load and changes nothing.

## Design constraints

| Constraint | How it is met |
|---|---|
| No system modification | Only reads existing files; no sysfs/tunable writes |
| No daemon, cron or timers | Post-processes history; nothing runs continuously |
| No `/proc` reads | Data comes from `journalctl` output and `sar -f` history files |
| No `nice` / `ionice` | Script does not change its own priority |
| Runs as non-root | Journal output is supplied as a text file (see below) |
| No files written | Only exception: one `mktemp` file when no boots file is given, deleted on exit |

## Requirements

- Bash, GNU `date`, `awk`, `sed`, `sort`
- `sar` from **sysstat**, with history already being collected (`/var/log/sa` or `/var/log/sysstat`, readable by the user)
- A persistent systemd journal, so `journalctl --list-boots` shows past boots

## Usage

**1. Once, from a session that can read the journal:**

```sh
journalctl --no-pager --list-boots > /tmp/boots.txt
chmod 644 /tmp/boots.txt
```

**2. As the non-root user:**

```sh
./reboot-io-summary.sh /tmp/boots.txt                # no per-disk rows (default)
./reboot-io-summary.sh -d sda,sdb /tmp/boots.txt     # only sda and sdb
./reboot-io-summary.sh -d ALL /tmp/boots.txt         # every device
./reboot-io-summary.sh -n 5 -d sda /tmp/boots.txt    # last 5 boots, sda only
```

### Options

| Option | Default | Meaning |
|---|---|---|
| `-d DEVICES` | none | Disks to show in the accumulated section: comma or space separated names as `sar` prints them (`sda`, `nvme0n1`, `ubuntu--vg-ubuntu--lv`), or `ALL` for every device. With no `-d`, no individual device rows are printed. A name with no data prints a note on stderr. |
| `-n N` | all | Only process the N most recent boots (lighter on the system) |
| `-h` | | Show usage |

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `BOOTS_FILE` | none | Saved `--list-boots` output (or pass as the positional argument) |
| `DEVICES` | none | Same as `-d` |
| `LAST_BOOTS` | all | Same as `-n` |
| `SA_DIRS` | `/var/log/sa /var/log/sysstat` | Where sysstat files live |
| `MAXGAP` | `1800` | Ignore sample gaps longer than this many seconds |

## Output

1. **Reboot timeline**: boot start, end, uptime, and downtime before each boot.
2. **Accumulated metrics per reboot interval**: one block of rows per boot window. Byte rates become total bytes, `tps`-type metrics become total IOs, and `%iowait`, `await`, `%util` and similar become time-weighted averages with maxima. `KEY` is `-` for the whole system and `all` for all CPUs (always shown), or a disk name (shown only if selected with `-d`).
3. **Per boot**: read/write GiB, transactions, average `%iowait`, max `%util` (worst disk, across all devices regardless of `-d`) and sar coverage; the latest boot is marked `<- latest`.
4. **Grand totals**: read bytes, write bytes and transactions across all listed boots.

Illustrative output for section 2 (excerpt):

```
IDX   KEY          METRIC         TOTAL_OR_AVG UNIT            MAX  COVERED_h
-1    -            bread/s            30720000 bytes       100.00        0.2
-1    -            bwrtn/s            92160000 bytes       300.00        0.2
-1    -            tps                   12000 IOs          20.00        0.2
-1    sda          %util                 30.00 avg          30.00        0.2
```

## How it works

1. Parses the boots file into start/end times, sorted oldest to newest.
2. For each boot window, runs `sar -b`, `sar -u` and `sar -d -p` against the per-day history files, restricted with `-s`/`-e`. The `DEV`/`CPU` column is located by name, so both older (`time DEV tps ...`) and newer (`time tps ... DEV`) sysstat layouts parse correctly.
3. Integrates each rate over the time between samples (value x seconds), so rates become totals.
4. Discards samples across a `LINUX RESTART` marker or a gap longer than `MAXGAP`, so crashes and restarts are never counted as activity.

## Limitations

- **sysstat must already have been collecting.** Boots with no sar data show `no sar data`.
- **Activity after the last sar sample before a crash is not recorded**, so a crashed boot's totals can be slightly low.
- **Figures are approximate** (rate x interval) and may differ slightly from `sar`'s own "Average:" lines.
- **Time zone and DST:** journal and sar times are both treated as local time; window edges can shift by an hour on a DST change day.
- **The boots file is a snapshot.** Regenerate it to include newer boots.

## sample output
vagrant@hermes-sandbox:~/scripts$ BOOTS_FILE=/tmp/boots.txt LAST_BOOTS=5 ./11oct26_reboot-io-summary_v3.bash -d sda
== Reboot timeline (journalctl) ==
IDX   BOOT     START               END                 UPTIME     DOWN_BEFORE
-4    db65f678 2026-10-07 08:20:03 2026-10-08 05:23:06 0d21h03m   -
-3    7021c65a 2026-10-08 08:33:46 2026-10-08 20:08:06 0d11h34m   0d03h10m
-2    c8c2f6e9 2026-10-09 08:27:02 2026-10-09 20:27:45 0d12h00m   0d12h18m
-1    f6dcb4f5 2026-10-10 14:59:10 2026-10-10 20:49:32 0d05h50m   0d18h31m
0     8a16289a 2026-10-11 10:39:28 2026-10-11 11:16:35 0d00h37m   0d13h49m

== Accumulated per reboot interval (sar) - devices: sda ==
IDX   KEY          METRIC         TOTAL_OR_AVG UNIT           MAX  COVERED_h
-4    -            bdscd/s                   0 bytes         0.00       20.3
-4    -            bread/s           619224274 bytes      1033.90       20.3
-4    -            bwrtn/s         15355670108 bytes     14340.20       20.3
-4    -            dtps                      0 IOs           0.00       20.3
-4    -            rtps                  54618 IOs          57.78       20.3
-4    -            tps                 1702034 IOs         191.83       20.3
-4    -            wtps                1647440 IOs         134.06       20.3
-4    all          %idle                 84.79 avg          86.82       20.3
-4    all          %iowait                0.16 avg           3.98       20.3
-4    all          %nice                  0.00 avg           0.10       20.3
-4    all          %steal                 0.00 avg           0.00       20.3
-4    all          %system                8.57 avg          33.85       20.3
-4    all          %user                  6.48 avg          22.35       20.3
-4    sda          %util                  1.52 avg           2.56       20.3
-4    sda          aqu-sz                 0.07 avg           0.11       20.3
-4    sda          areq-sz                6.13 avg          11.97       20.3
-4    sda          await                  4.18 avg           6.10       20.3
-4    sda          dkB/s                     0 bytes         0.00       20.3
-4    sda          rkB/s             130412564 bytes        85.57       20.3
-4    sda          tps                 1197894 IOs          23.49       20.3
-4    sda          wkB/s            7318616535 bytes       125.08       20.3
-3    -            bdscd/s                   0 bytes         0.00       11.2
-3    -            bread/s            59617935 bytes       103.68       11.2
-3    -            bwrtn/s          3562297078 bytes       222.81       11.2
-3    -            dtps                      0 IOs           0.00       11.2
-3    -            rtps                    772 IOs           0.64       11.2
-3    -            tps                  562688 IOs          16.32       11.2
-3    -            wtps                 561892 IOs          16.32       11.2
-3    all          %idle                 91.15 avg          92.04       11.2
-3    all          %iowait                0.09 avg           0.20       11.2
-3    all          %nice                  0.00 avg           0.00       11.2
-3    all          %steal                 0.00 avg           0.00       11.2
-3    all          %system                6.79 avg          10.72       11.2
-3    all          %user                  1.96 avg           3.31       11.2
-3    sda          %util                  1.12 avg           1.99       11.2
-3    sda          aqu-sz                 0.05 avg           0.10       11.2
-3    sda          areq-sz                6.29 avg          14.93       11.2
-3    sda          await                  4.04 avg           7.35       11.2
-3    sda          dkB/s                     0 bytes         0.00       11.2
-3    sda          rkB/s              56794552 bytes        51.84       11.2
-3    sda          tps                  516122 IOs          15.18       11.2
-3    sda          wkB/s            3231117507 bytes       103.90       11.2
-2    -            bdscd/s                   0 bytes         0.00       11.7
-2    -            bread/s           506288445 bytes      1433.44       11.7
-2    -            bwrtn/s          3759985807 bytes       409.76       11.7
-2    -            dtps                      0 IOs           0.00       11.7
-2    -            rtps                  12317 IOs          17.96       11.7
-2    -            tps                  593774 IOs          34.54       11.7
-2    -            wtps                 581427 IOs          16.96       11.7
-2    all          %idle                 89.92 avg          90.64       11.7
-2    all          %iowait                0.11 avg           0.94       11.7
-2    all          %nice                  0.00 avg           0.01       11.7
-2    all          %steal                 0.00 avg           0.00       11.7
-2    all          %system                7.21 avg          13.18       11.7
-2    all          %user                  2.76 avg          15.40       11.7
-2    sda          %util                  1.42 avg           1.75       11.7
-2    sda          aqu-sz                 0.07 avg           0.08       11.7
-2    sda          areq-sz                6.29 avg          11.32       11.7
-2    sda          await                  4.98 avg           6.33       11.7
-2    sda          dkB/s                     0 bytes         0.00       11.7
-2    sda          rkB/s              56293100 bytes        47.88       11.7
-2    sda          tps                  544090 IOs          15.86       11.7
-2    sda          wkB/s            3415878871 bytes       104.42       11.7
-1    -            bdscd/s                   0 bytes         0.00        5.5
-1    -            bread/s           131334963 bytes       170.66        5.5
-1    -            bwrtn/s          2165819515 bytes       334.98        5.5
-1    -            dtps                      0 IOs           0.00        5.5
-1    -            rtps                   5941 IOs           3.62        5.5
-1    -            tps                  325513 IOs          25.67        5.5
-1    -            wtps                 319554 IOs          22.06        5.5
-1    all          %idle                 88.97 avg          90.07        5.5
-1    all          %iowait                0.12 avg           0.25        5.5
-1    all          %nice                  0.00 avg           0.01        5.5
-1    all          %steal                 0.00 avg           0.00        5.5
-1    all          %system                7.68 avg           8.27        5.5
-1    all          %user                  3.23 avg           4.13        5.5
-1    sda          %util                  1.44 avg           2.09        5.5
-1    sda          aqu-sz                 0.07 avg           0.09        5.5
-1    sda          areq-sz                6.83 avg          15.51        5.5
-1    sda          await                  4.98 avg           5.45        5.5
-1    sda          dkB/s                     0 bytes         0.00        5.5
-1    sda          rkB/s              88066355 bytes        59.84        5.5
-1    sda          tps                  258421 IOs          18.07        5.5
-1    sda          wkB/s            1694575626 bytes       125.60        5.5
0     -            bdscd/s                   0 bytes         0.00        0.3
0     -            bread/s            29735030 bytes        95.84        0.3
0     -            bwrtn/s            92215818 bytes       154.79        0.3
0     -            dtps                      0 IOs           0.00        0.3
0     -            rtps                    478 IOs           0.60        0.3
0     -            tps                   13241 IOs          11.76        0.3
0     -            wtps                  12764 IOs          11.16        0.3
0     all          %idle                 91.11 avg          91.16        0.3
0     all          %iowait                0.09 avg           0.10        0.3
0     all          %nice                  0.00 avg           0.00        0.3
0     all          %steal                 0.00 avg           0.00        0.3
0     all          %system                6.60 avg           6.60        0.3
0     all          %user                  2.20 avg           2.25        0.3
0     sda          %util                  1.35 avg           1.42        0.3
0     sda          aqu-sz                 0.06 avg           0.06        0.3
0     sda          areq-sz                8.90 avg          10.71        0.3
0     sda          await                  5.23 avg           5.25        0.3
0     sda          dkB/s                     0 bytes         0.00        0.3
0     sda          rkB/s              29731953 bytes        47.92        0.3
0     sda          tps                   12984 IOs          11.53        0.3
0     sda          wkB/s              90062203 bytes        75.52        0.3

== Per boot ==
IDX   START               UPTIME     DOWN        READ_GiB WRITE_GiB TRANSACTIONS  %iowait max%util  covered
-4    2026-10-07 08:20:03 0d21h03m   -               0.58     14.30      1702034      0.2     23.3    20.3h
-3    2026-10-08 08:33:46 0d11h34m   0d03h10m        0.06      3.32       562688      0.1      2.2    11.2h
-2    2026-10-09 08:27:02 0d12h00m   0d12h18m        0.47      3.50       593774      0.1      5.0    11.7h
-1    2026-10-10 14:59:10 0d05h50m   0d18h31m        0.12      2.02       325513      0.1      2.3     5.5h
0     2026-10-11 10:39:28 0d00h37m   0d13h49m        0.03      0.09        13241      0.1      1.5     0.3h  <- latest

== Grand totals across listed boots (sar -b) ==
read_bytes             1346200648
write_bytes           24935988326
transactions              3197250

- **`sar -d -p`** may read `/dev/mapper` names. Remove `-p` in `run_boot` to avoid this; devices then show as `devM-N`.
- Block units follow sysstat: `bread/s` and `bwrtn/s` are 512-byte blocks per second.
