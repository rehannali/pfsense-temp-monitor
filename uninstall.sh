#!/bin/sh
#
# pfSense Temperature Monitor - uninstaller
#
#   fetch -qo - https://raw.githubusercontent.com/rehannali/pfsense-temp-monitor/main/uninstall.sh | sh
#
# Add "-s -- --purge" after "sh" to also delete the config file and log.
#

BIN_DIR="${TEMP_MONITOR_BIN_DIR:-/usr/local/bin}"
CONF_FILE="${TEMP_MONITOR_CONF:-/usr/local/etc/temp_monitor.conf}"
CRONTAB="${TEMP_MONITOR_CRONTAB:-/etc/crontab}"
PHP="${TEMP_MONITOR_PHP:-/usr/local/bin/php}"
LOG_FILE="/var/log/temperature_monitor.log"
PURGE=no

[ "$1" = "--purge" ] && PURGE=yes
[ "$(id -u)" = "0" ] || { echo "ERROR: This must be run as root" >&2; exit 1; }

# Pick up a custom log location before the config file is removed
[ -f "$CONF_FILE" ] && . "$CONF_FILE"

remove_cron() {
    [ -x "$PHP" ] && [ -f /etc/inc/services.inc ] || return 1
    "$PHP" -r '
        require_once("config.inc");
        require_once("services.inc");
        install_cron_job($argv[1], false);
    ' -- "$1" >/dev/null 2>&1
}

echo "pfSense Temperature Monitor - uninstalling"

for cmd in "$BIN_DIR/temp_monitor.sh" \
           "$BIN_DIR/temp_report.sh daily --send" \
           "$BIN_DIR/temp_report.sh weekly --send" \
           "$BIN_DIR/temp_report.sh monthly --send"; do
    remove_cron "$cmd"
done

# Remove any line that was added to the crontab by hand
if grep -q "temp_monitor.sh\|temp_report.sh" "$CRONTAB" 2>/dev/null; then
    grep -v "temp_monitor.sh\|temp_report.sh" "$CRONTAB" > "${CRONTAB}.tmp" && cat "${CRONTAB}.tmp" > "$CRONTAB"
    rm -f "${CRONTAB}.tmp"
fi
echo "  Removed cron jobs"

for f in temp_monitor.sh temp_report.sh temp_dashboard.sh; do
    rm -f "$BIN_DIR/$f"
done
echo "  Removed scripts from $BIN_DIR"

rm -f /tmp/temp_monitor_state

if [ "$PURGE" = "yes" ]; then
    rm -f "$CONF_FILE" "$LOG_FILE"
    echo "  Removed $CONF_FILE and $LOG_FILE"
else
    echo "  Kept $CONF_FILE and $LOG_FILE (use --purge to delete them)"
fi

echo "Done."
