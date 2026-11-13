#!/bin/sh
#
# pfSense Temperature Monitor - installer
#
# One-line install (run as root on the firewall):
#   fetch -qo - https://raw.githubusercontent.com/rehannali/pfsense-temp-monitor/main/install.sh | sh
#
# With scheduled daily/weekly/monthly reports:
#   fetch -qo - https://raw.githubusercontent.com/rehannali/pfsense-temp-monitor/main/install.sh | sh -s -- --with-reports
#
# Safe to re-run: it updates the scripts and leaves your config file alone.
#

REPO_RAW="${TEMP_MONITOR_REPO:-https://raw.githubusercontent.com/rehannali/pfsense-temp-monitor/main}"
REPO_GIT="${TEMP_MONITOR_REPO_GIT:-https://github.com/rehannali/pfsense-temp-monitor.git}"
REPO_BRANCH="${TEMP_MONITOR_REPO_BRANCH:-main}"
BIN_DIR="${TEMP_MONITOR_BIN_DIR:-/usr/local/bin}"
CONF_FILE="${TEMP_MONITOR_CONF:-/usr/local/etc/temp_monitor.conf}"
CRONTAB="${TEMP_MONITOR_CRONTAB:-/etc/crontab}"
PHP="${TEMP_MONITOR_PHP:-/usr/local/bin/php}"
SCRIPTS="temp_monitor.sh temp_report.sh temp_dashboard.sh"

WITH_REPORTS=no
SEND_TEST=no

for arg in "$@"; do
    case "$arg" in
        --with-reports) WITH_REPORTS=yes ;;
        --test)         SEND_TEST=yes ;;
        --help|-h)
            echo "Usage: install.sh [--with-reports] [--test]"
            echo "  --with-reports  Also schedule daily, weekly and monthly reports"
            echo "  --test          Send a test notification when finished"
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $arg (use --help)" >&2
            exit 2
            ;;
    esac
done

say()  { echo "  $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

# Download $1 (URL) to $2 (file) using whichever tool exists
download() {
    if command -v fetch >/dev/null 2>&1; then
        fetch -qo "$2" "$1"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$2" "$1"
    else
        return 1
    fi
}

# Make sure git is available, installing it with pkg if we can
ensure_git() {
    command -v git >/dev/null 2>&1 && return 0
    command -v pkg >/dev/null 2>&1 || return 1
    say "git not found; installing it with pkg"
    pkg install -y git >/dev/null 2>&1 && command -v git >/dev/null 2>&1
}

# Clone the repository into $1 (shallow, single branch)
clone_repo() {
    ensure_git || return 1
    git clone --quiet --depth 1 --branch "$REPO_BRANCH" "$REPO_GIT" "$1" 2>/dev/null
}

# Register a cron job in pfSense's own configuration so it survives
# reboots and updates. Args: command minute hour mday month wday
add_cron() {
    [ -x "$PHP" ] && [ -f /etc/inc/services.inc ] || return 1
    "$PHP" -r '
        require_once("config.inc");
        require_once("services.inc");
        install_cron_job($argv[1], true, $argv[2], $argv[3], $argv[4], $argv[5], $argv[6], "root", true);
    ' -- "$@" >/dev/null 2>&1
}

echo "pfSense Temperature Monitor - installing"
echo ""

[ "$(id -u)" = "0" ] || fail "This installer must be run as root"
[ -f /etc/inc/config.inc ] || say "Note: this does not look like pfSense; continuing anyway"

# 1. Get the scripts. In order of preference:
#    a) a local clone, when the installer is run from one
#    b) raw files downloaded with fetch or curl
#    c) a git clone (git is installed with pkg if it is missing)
SRC_DIR=""
case "$0" in
    */*) [ -f "$(dirname "$0")/scripts/temp_monitor.sh" ] && SRC_DIR="$(dirname "$0")" ;;
    *)   [ -f "./$0" ] && [ -f "./scripts/temp_monitor.sh" ] && SRC_DIR="." ;;
esac

TMP_DIR=$(mktemp -d /tmp/temp_monitor_install.XXXXXX) || fail "Could not create a temp directory"
trap 'rm -rf "$TMP_DIR"' EXIT

# Copy the needed files from a source tree ($1) into $TMP_DIR
copy_from_tree() {
    for f in $SCRIPTS temp_monitor.conf.sample; do
        case "$f" in
            *.sh) cp "$1/scripts/$f" "$TMP_DIR/$f" 2>/dev/null ;;
            *)    cp "$1/$f" "$TMP_DIR/$f" 2>/dev/null ;;
        esac
    done
}

# Download the needed files one by one into $TMP_DIR
download_files() {
    for f in $SCRIPTS temp_monitor.conf.sample; do
        case "$f" in
            *.sh) download "$REPO_RAW/scripts/$f" "$TMP_DIR/$f" ;;
            *)    download "$REPO_RAW/$f" "$TMP_DIR/$f" ;;
        esac
    done
}

# True when every needed file is present and non-empty in $TMP_DIR
have_all_files() {
    for f in $SCRIPTS temp_monitor.conf.sample; do
        [ -s "$TMP_DIR/$f" ] || return 1
    done
}

if [ -n "$SRC_DIR" ]; then
    say "Source: local copy in $SRC_DIR"
    copy_from_tree "$SRC_DIR"
else
    if command -v fetch >/dev/null 2>&1 || command -v curl >/dev/null 2>&1; then
        say "Source: downloading from $REPO_RAW"
        download_files
    else
        say "Neither fetch nor curl found"
    fi
    if ! have_all_files; then
        say "Source: cloning $REPO_GIT with git"
        clone_repo "$TMP_DIR/repo" \
            || fail "Could not clone $REPO_GIT (git unavailable and pkg could not install it)"
        copy_from_tree "$TMP_DIR/repo"
    fi
fi

for f in $SCRIPTS temp_monitor.conf.sample; do
    [ -s "$TMP_DIR/$f" ] || fail "Could not get $f"
done

# Refuse to install anything that is not one of our shell scripts
for f in $SCRIPTS; do
    head -1 "$TMP_DIR/$f" | grep -q '^#!/bin/sh' || fail "$f does not look like a shell script"
done

# 2. Copy scripts into place with the right owner and permissions
mkdir -p "$BIN_DIR"
for f in $SCRIPTS; do
    install -o root -g wheel -m 0755 "$TMP_DIR/$f" "$BIN_DIR/$f" 2>/dev/null \
        || install -m 0755 "$TMP_DIR/$f" "$BIN_DIR/$f" \
        || fail "Could not install $BIN_DIR/$f"
    say "Installed $BIN_DIR/$f"
done

# 3. Config file: created once, never overwritten
if [ -f "$CONF_FILE" ]; then
    say "Kept existing $CONF_FILE"
else
    mkdir -p "$(dirname "$CONF_FILE")"
    install -m 0644 "$TMP_DIR/temp_monitor.conf.sample" "$CONF_FILE" \
        && say "Created $CONF_FILE"
fi

# 4. Cron jobs
MONITOR_CMD="$BIN_DIR/temp_monitor.sh"
if add_cron "$MONITOR_CMD" "*/5" "*" "*" "*" "*" && grep -q "temp_monitor.sh" "$CRONTAB" 2>/dev/null; then
    say "Cron: monitor every 5 minutes (stored in pfSense config)"
elif grep -q "temp_monitor.sh" "$CRONTAB" 2>/dev/null; then
    say "Cron: monitor job already present in $CRONTAB"
else
    echo "*/5 * * * * root $MONITOR_CMD" >> "$CRONTAB"
    say "Cron: added to $CRONTAB directly. pfSense may remove this line on"
    say "      reboot; re-run the installer or add it with the Cron package."
fi

if [ "$WITH_REPORTS" = "yes" ]; then
    REPORT_CMD="$BIN_DIR/temp_report.sh"
    if add_cron "$REPORT_CMD daily --send"   "0"  "8" "*" "*" "*" \
    && add_cron "$REPORT_CMD weekly --send"  "5"  "8" "*" "*" "1" \
    && add_cron "$REPORT_CMD monthly --send" "10" "8" "1" "*" "*"; then
        say "Cron: reports daily 08:00, weekly Mon 08:05, monthly 1st 08:10"
    else
        say "Cron: could not schedule reports automatically; add them with the Cron package"
    fi
fi

# 5. Sensor check and first reading
echo ""
if TEMP=$(sysctl -n dev.cpu.0.temperature 2>/dev/null) && [ -n "$TEMP" ]; then
    say "Sensor check: CPU 0 is at $TEMP"
    "$MONITOR_CMD" >/dev/null 2>&1 && say "Logged a first reading"
else
    say "WARNING: no CPU temperature sensor found."
    say "Enable one in System > Advanced > Miscellaneous > Thermal Sensors"
    say "(Intel Core or AMD), then run: $MONITOR_CMD --status"
fi

if [ "$SEND_TEST" = "yes" ]; then
    echo ""
    "$MONITOR_CMD" --test
fi

echo ""
echo "Done. Useful commands:"
say "$BIN_DIR/temp_monitor.sh --status        current temperatures"
say "$BIN_DIR/temp_monitor.sh --check-config  notification channels"
say "$BIN_DIR/temp_monitor.sh --test          send a test alert"
say "$BIN_DIR/temp_report.sh daily            report for the last 24 hours"
say "$BIN_DIR/temp_dashboard.sh               live dashboard"
say "Settings: $CONF_FILE"
