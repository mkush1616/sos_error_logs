# sos_error_scan

A Bash script that scans the `/var/log/` directory of a customer-provided **sosreport** and extracts **error messages only**. It has extra awareness of **Red Hat Satellite 6** logs (Foreman, Katello, Candlepin, Pulp, Smart Proxy and more).

It is designed for support engineers who work through many cases, each holding several sosreports, and want a fast first-pass triage without opening every log by hand.

---

## Features

- Interactive: prompts for the **case number**, then lets you choose which **sosreport** to analyse (one, several, or all).
- Finds sosreports anywhere under the case directory, both extracted directories and `sosreport-*.tar.*` archives. It offers to extract archives for you.
- Reads **every file** in the sosreport's `var/log/`, including rotated and compressed logs (`.gz`, `.xz`, `.bz2`, `.zst`).
- Skips binary and irrelevant files (`wtmp`, `btmp`, `lastlog`, `sa/`, journal binaries, and so on). `audit.log` is skipped by default and can be included with `-a`.
- Reports **error lines only**, with common false positives filtered out (for example "0 errors" or "no error").
- **Satellite 6 aware:**
  - `foreman/production.log` is matched by log level (`[E|` and `[F|`) and Foreman `ERFxx-xxxx` error codes, instead of a noisy keyword search.
  - Each log is labelled by component (Foreman/Katello/Dynflow, Candlepin, Pulp, Smart Proxy, httpd, Tomcat, PostgreSQL, Qpid/Qdrouterd, MongoDB, Redis, Puppet, Installer/Maintain, rhsm, system logs).
  - Detects the installed Satellite package version from the sosreport.
  - Optionally scans `journalctl` output from `sos_commands/logs`, useful on newer Satellite 6.x where services log to the journal.
- Produces a summary report plus per-file results with **original line numbers**.
- Groups recurring errors by normalising timestamps, UUIDs, request IDs, hex values and numbers.

---

## Requirements

| Requirement | Notes |
|---|---|
| Bash 4.x or newer | Default on RHEL 7, 8 and 9 |
| GNU grep, sed, awk, find, sort, tar | Standard on RHEL |
| `zcat`, `xzcat`, `bzcat` | For rotated logs (`gzip`, `xz` and `bzip2` packages) |
| `zstdcat` | Optional, only for `.zst` logs |

No root privileges are needed, only read and write access to the case directory.

---

## Installation

```bash
git clone https://github.com/<your-username>/<your-repo>.git
cd <your-repo>
chmod +x sos_error_scan.sh
```

---

## Expected directory layout

By default the script looks under `/home/test/mohitk`:

```
/home/test/mohitk/
└── 48573475/                         <- case number
    ├── some_directory/
    │   └── sosreport-sat01-2026-01-01-abcdef/   <- extracted sosreport
    │       ├── etc/
    │       ├── sos_commands/
    │       └── var/log/
    └── another_directory/
        └── sosreport-sat02-2026-01-01-ghijkl.tar.xz   <- archive, extracted on request
```

Directory depth does not matter. The script searches the whole case directory.

To use a different base path, change `BASE_DIR` at the top of the script or pass `-b`.

---

## Usage

```bash
./sos_error_scan.sh                  # fully interactive
./sos_error_scan.sh -c 48573475      # skip the case prompt
./sos_error_scan.sh -b /other/path   # use a different base directory
./sos_error_scan.sh -a               # also scan audit.log (very noisy)
./sos_error_scan.sh -h               # show help
```

| Option | Description |
|---|---|
| `-b <dir>` | Base directory that contains the case directories (default `/home/test/mohitk`) |
| `-c <case>` | Case number, skips the case prompt |
| `-a` | Include `audit.log` files, which are skipped by default |
| `-h` | Show help |

### Interactive flow

```
[*] Cases found in /home/test/mohitk:
48573475  48573999

Enter case number: 48573475

[*] Sosreports found in case 48573475:
   1) sub/sosreport-sat01-2026   (host: sat01)
   2) other/sosreport-sat02-2026.tar.xz   [archive - not extracted yet]

Select sosreport number(s) (space separated) or 'all': 1
Also scan journalctl output in sos_commands/logs (useful for newer Satellite 6.x)? [y/N]: n
```

---

## Output

Results are printed to the screen and saved in the case directory:

```
<case>/error_analysis/<sosreport-name>_<timestamp>/
├── summary.txt          <- overview report (same as the screen output)
└── files/
    ├── var_log_foreman_production.log.txt
    ├── var_log_candlepin_error.log.txt
    └── ...              <- one file per log that contained errors
```

The `files/*.txt` entries keep the **original line numbers** (`LINE:content`), so you can jump straight to the context in the real log.

### Example summary

```
==============================================================
 SOSREPORT ERROR ANALYSIS
==============================================================
 Case          : 48573475
 Sosreport     : /home/test/mohitk/48573475/sub/sosreport-sat01-2026
 Hostname      : sat01
 OS            : Red Hat Enterprise Linux release 8.9
 Satellite pkg : satellite-6.x.y-z.el8sat.noarch
 Files scanned : 3
 Files w/errors: 3
 Error lines   : 4

---- Errors by component ----
        2  Satellite: Foreman/Katello/Dynflow
        1  Satellite: Smart Proxy
        1  Satellite: Candlepin

---- Top 25 recurring error messages (numbers/timestamps/UUIDs normalised) ----
      2  [E|app|id] Failed to connect N
      1  ERROR [x] boom
```

The report also lists files ranked by error count and the last 5 error lines of each current Satellite log.

---

## How errors are detected

| Log type | Detection method |
|---|---|
| `foreman/production.log*` | Log level `[E|` or `[F|` and Foreman `ERFxx-xxxx` codes |
| Everything else | Case-insensitive match on `error`, `fatal`, `critical`, `crit`, `fail/failed/failure/failing`, `exception`, `traceback`, `panic`, `segfault`, `oom-killer`, `out of memory`, `denied`, `unable to`, `cannot`, `could not`, `timeout/timed out` |

Lines that match the pattern but are not real errors (for example `0 errors`, `no errors`, `errors=0`, `ErrorDocument`, `LogLevel`) are excluded.

### Customising the pattern

The generic pattern is intentionally broad. If it is too noisy, narrow it with an environment variable:

```bash
ERROR_PATTERN='\b(error|fatal|traceback|exception)\b' ./sos_error_scan.sh
```

You can also edit `GENERIC_PAT`, `SAT_PAT` and `EXCL_PAT` near the top of the script.

---

## Satellite 6 log coverage

The script labels and scans these locations among others:

| Component | Typical path |
|---|---|
| Foreman / Katello / Dynflow | `/var/log/foreman/` |
| Smart Proxy | `/var/log/foreman-proxy/` |
| Candlepin | `/var/log/candlepin/` |
| Tomcat | `/var/log/tomcat*/` |
| Pulp | `/var/log/pulp*` |
| Apache httpd | `/var/log/httpd/` |
| Qpid / Qdrouterd | `/var/log/qpid*`, `/var/log/qdrouterd/` |
| PostgreSQL | `/var/log/postgresql/`, `/var/log/rh-postgresql*/` |
| Installer / Maintain | `/var/log/foreman-installer/`, `/var/log/foreman-maintain/` |
| MongoDB, Redis, Puppet | `/var/log/mongodb/`, `/var/log/redis/`, `/var/log/puppetlabs/` |
| System | `/var/log/messages*`, `secure*`, `cron*`, `dmesg*`, `boot.log*` |

Any other file under `/var/log/` is still scanned and shown under the `Other` label.

---

## Limitations

- Only lines that match the error pattern are shown. Multi-line backtraces following an error line are **not** included, so use the saved line numbers to read the surrounding context in the original log.
- Matching is text-based and does not understand every application's log format. Expect some false positives, especially from the generic pattern.
- Binary logs (for example native systemd journal files) are skipped. Use the optional `sos_commands/logs` journal scan instead.
- Extracting an archive as a non-root user may print warnings for special files. This is harmless for log analysis.
- This is a triage aid. It does not replace reading the logs and applying Red Hat Knowledge Base articles to the findings.

---

## Contributing

Issues and pull requests are welcome, especially for new Satellite component paths or better error patterns for specific services.

## License

Add your preferred license here (for example MIT) and include a `LICENSE` file in the repository.
