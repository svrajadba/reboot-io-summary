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
- **`sar -d -p`** may read `/dev/mapper` names. Remove `-p` in `run_boot` to avoid this; devices then show as `devM-N`.
- Block units follow sysstat: `bread/s` and `bwrtn/s` are 512-byte blocks per second.
