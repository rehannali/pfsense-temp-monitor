# pfSense Temperature Monitor

CPU temperature monitoring for pfSense: a reading every 5 minutes, alerts
through pfSense's own notification channels (email, Telegram, Slack,
Pushover), daily/weekly/monthly reports, and a live terminal dashboard.

It is plain `/bin/sh` and uses only what pfSense already ships. No packages
are required.

## Install

Run this as root on the firewall (console option 8, or SSH):

```sh
fetch -qo - https://raw.githubusercontent.com/rehannali/pfsense-temp-monitor/main/install.sh | sh
```

To also schedule the reports (daily 08:00, weekly Monday 08:05, monthly on
the 1st at 08:10), each sent to your notification channels:

```sh
fetch -qo - https://raw.githubusercontent.com/rehannali/pfsense-temp-monitor/main/install.sh | sh -s -- --with-reports
```

Add `--test` to send a test notification at the end.

The installer:

1. Downloads the three scripts to `/usr/local/bin` and makes them executable.
2. Creates `/usr/local/etc/temp_monitor.conf` if it does not exist.
3. Registers the cron job in pfSense's configuration, so it survives reboots
   and updates. (A line added to `/etc/crontab` by hand does not.)
4. Checks that a temperature sensor is readable and logs a first reading.

It is safe to re-run. Re-running updates the scripts and keeps your config
file.

## Requirements

- pfSense CE or Plus. Developed on 2.9.0 with an Intel N100.
- A CPU thermal sensor enabled under **System > Advanced > Miscellaneous >
  Thermal Sensors** (Intel Core or AMD).
- For alerts: at least one channel set up under **System > Advanced >
  Notifications**.

## Usage

| Command | What it does |
| --- | --- |
| `temp_monitor.sh` | Take a reading, log it, alert if over a threshold (this is what cron runs) |
| `temp_monitor.sh --status` | Show current temperatures and thresholds |
| `temp_monitor.sh --check-config` | Show which notification channels pfSense has configured |
| `temp_monitor.sh --test` | Send a test notification |
| `temp_monitor.sh --log` | Show the last 20 log entries |
| `temp_report.sh daily` | Report for the last 24 hours |
| `temp_report.sh weekly` | Report for the last 7 days |
| `temp_report.sh monthly` | Report for the last 30 days |
| `temp_report.sh daily --send` | Generate the report and send it to your channels |
| `temp_dashboard.sh` | Live dashboard, refreshed every 2 seconds (Ctrl+C to exit) |

## Configuration

Edit `/usr/local/etc/temp_monitor.conf`. Every setting is listed there,
commented out, with its default. The main ones:

| Setting | Default | Meaning |
| --- | --- | --- |
| `TEMP_INFO` | 60 | Log a notice at or above this temperature (°C) |
| `TEMP_WARNING` | 70 | Send a warning |
| `TEMP_CRITICAL` | 80 | Send an urgent alert |
| `TEMP_EMERGENCY` | 90 | Send repeated alerts |
| `ENABLE_EMAIL`, `ENABLE_TELEGRAM`, `ENABLE_SLACK`, `ENABLE_PUSHOVER` | true | Which channels to use |
| `LOG_FILE` | `/var/log/temperature_monitor.log` | Where readings are stored |
| `LOG_RETENTION_DAYS` | 30 | Older entries are trimmed once a day |

Alerts of the same level are rate-limited: 30 minutes for warnings, 10 for
critical, 5 for emergency.

## Troubleshooting

**"No data found for period starting ..."**
The log has no readings in the requested period. Check that cron is running
the monitor (`grep temp_monitor /etc/crontab`) and that the log is growing
(`temp_monitor.sh --log`).

**History disappears after a reboot**
If `/var` is a RAM disk (`df -h /var` shows `tmpfs`), `/var/log` is wiped on
reboot. Set `LOG_FILE` in the config file to a path on disk, for example
`/root/temperature_monitor.log`.

**"Unable to read CPU temperature"**
Enable the thermal sensor driver (see Requirements), then run
`temp_monitor.sh --status`.

**No notifications arrive**
Run `temp_monitor.sh --check-config` to see which channels pfSense has
configured, then `temp_monitor.sh --test`.

## Uninstall

```sh
fetch -qo - https://raw.githubusercontent.com/rehannali/pfsense-temp-monitor/main/uninstall.sh | sh
```

This removes the scripts and cron jobs and keeps your config file and log.
To delete those too, use `| sh -s -- --purge`.

## Manual install

```sh
git clone https://github.com/rehannali/pfsense-temp-monitor.git
cd pfsense-temp-monitor
sh install.sh
```

## License

MIT. See [LICENSE](LICENSE).
