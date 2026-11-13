#!/bin/sh
#
# pfSense Temperature Monitor with Multi-Channel Notifications
# Tuned for low-power fanless boxes (e.g. Intel N100); thresholds are configurable
# Supports: Email, Telegram, Slack, Pushover via pfSense native system
#

##############################################################################
# CONFIGURATION - Adjust these values
##############################################################################

# Temperature Thresholds (in Celsius)
TEMP_INFO=60        # Info level - log only
TEMP_WARNING=70     # Warning - send notification
TEMP_CRITICAL=80    # Critical - urgent notification
TEMP_EMERGENCY=90   # Emergency - repeated notifications

# Notification Channel Toggles (true/false)
ENABLE_EMAIL=true
ENABLE_TELEGRAM=true
ENABLE_SLACK=true
ENABLE_PUSHOVER=true

# Use notify_all_remote() to send to ALL configured channels at once
# If false, uses individual toggles above
USE_UNIFIED=false

# Logging Configuration
LOG_FILE="/var/log/temperature_monitor.log"
LOG_READINGS=true       # Log every reading
LOG_RETENTION_DAYS=30   # Keep logs for 30 days

# Notification Cooldown (seconds) - prevents spam
COOLDOWN_WARNING=1800   # 30 minutes between warning alerts
COOLDOWN_CRITICAL=600   # 10 minutes between critical alerts
COOLDOWN_EMERGENCY=300  # 5 minutes between emergency alerts

# State file for cooldown tracking
STATE_FILE="/tmp/temp_monitor_state"

# Optional overrides. Put your own values in this file instead of editing
# the script, so they survive re-running the installer.
CONF_FILE="/usr/local/etc/temp_monitor.conf"
[ -f "$CONF_FILE" ] && . "$CONF_FILE"

##############################################################################
# HELPER FUNCTIONS
##############################################################################

# Get current timestamp
get_timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

# Get all CPU core temperatures
get_cpu_temps() {
    sysctl dev.cpu | grep temperature | awk -F': ' '{print $2}' | sed 's/C//'
}

# Get maximum CPU temperature across all cores
get_max_temp() {
    get_cpu_temps | sort -rn | head -1 | cut -d'.' -f1
}

# Get average CPU temperature
get_avg_temp() {
    get_cpu_temps | awk '{sum+=$1; count++} END {printf "%.1f", sum/count}'
}

# Get current CPU frequency in MHz
get_cpu_freq() {
    sysctl -n dev.cpu.0.freq 2>/dev/null || echo "N/A"
}

# Log temperature reading to file and syslog
log_reading() {
    local max_temp=$1
    local avg_temp=$2
    local freq=$3
    local timestamp=$(get_timestamp)
    
    if [ "$LOG_READINGS" = "true" ]; then
        echo "$timestamp | MAX: ${max_temp}°C | AVG: ${avg_temp}°C | FREQ: ${freq}MHz" >> "$LOG_FILE"
    fi
    
    logger -t temp_monitor "CPU Temp - Max: ${max_temp}°C, Avg: ${avg_temp}°C, Freq: ${freq}MHz"
}

# Check if cooldown period has passed since last notification
check_cooldown() {
    local level=$1
    local cooldown_var="COOLDOWN_${level}"
    local cooldown_time=$(eval echo \$$cooldown_var)
    
    if [ ! -f "$STATE_FILE" ]; then
        return 0  # No state file, allow notification
    fi
    
    local last_alert=$(grep "^${level}=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2)
    if [ -z "$last_alert" ]; then
        return 0  # No previous alert, allow
    fi
    
    local current_time=$(date +%s)
    local time_diff=$((current_time - last_alert))
    
    if [ $time_diff -ge $cooldown_time ]; then
        return 0  # Cooldown passed, allow
    else
        return 1  # Still in cooldown, block
    fi
}

# Update cooldown state after sending notification
update_cooldown() {
    local level=$1
    local current_time=$(date +%s)
    
    # Remove old entry if exists
    if [ -f "$STATE_FILE" ]; then
        grep -v "^${level}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null
        mv "${STATE_FILE}.tmp" "$STATE_FILE" 2>/dev/null
    fi
    
    # Add new timestamp
    echo "${level}=${current_time}" >> "$STATE_FILE"
}

# Send notifications via pfSense native notification system
send_notification() {
    local title=$1
    local message=$2
    
    # Escape single quotes for PHP
    local escaped_title=$(echo "$title" | sed "s/'/\\\'/g")
    local escaped_message=$(echo "$message" | sed "s/'/\\\'/g")
    
    if [ "$USE_UNIFIED" = "true" ]; then
        # Send to ALL configured channels at once
        /usr/local/bin/php << PHPEOF
<?php
require_once('/etc/inc/globals.inc');
require_once('/etc/inc/config.inc');
require_once('/etc/inc/notices.inc');

\$title = '${escaped_title}';
\$message = '${escaped_message}';

// Send to all configured notification channels
notify_all_remote(\$message);

// Also create notice in pfSense GUI
file_notice('temp_monitor', \$message, \$title, '');

log_error("Temperature Monitor: Sent to all configured channels");
?>
PHPEOF
    else
        # Send to individual channels based on toggles
        /usr/local/bin/php << PHPEOF
<?php
require_once('/etc/inc/globals.inc');
require_once('/etc/inc/config.inc');
require_once('/etc/inc/notices.inc');

\$title = '${escaped_title}';
\$message = '${escaped_message}';
\$channels_sent = array();

// Email (SMTP)
if ('${ENABLE_EMAIL}' === 'true') {
    notify_via_smtp(\$message, true);
    \$channels_sent[] = 'Email';
}

// Telegram
if ('${ENABLE_TELEGRAM}' === 'true') {
    notify_via_telegram(\$message, true);
    \$channels_sent[] = 'Telegram';
}

// Slack
if ('${ENABLE_SLACK}' === 'true') {
    notify_via_slack(\$message, true);
    \$channels_sent[] = 'Slack';
}

// Pushover
if ('${ENABLE_PUSHOVER}' === 'true') {
    notify_via_pushover(\$message, true);
    \$channels_sent[] = 'Pushover';
}

// Create notice in pfSense GUI
file_notice('temp_monitor', \$message, \$title, '');

// Log which channels were used
if (count(\$channels_sent) > 0) {
    log_error("Temperature Monitor: Notification sent via " . implode(', ', \$channels_sent));
} else {
    log_error("Temperature Monitor: No notification channels enabled");
}
?>
PHPEOF
    fi
    
    if [ $? -eq 0 ]; then
        logger -t temp_monitor "Notification sent: $title"
        return 0
    else
        logger -t temp_monitor "ERROR: Failed to send notification"
        return 1
    fi
}

# Main notification function with cooldown logic
notify() {
    local level=$1
    local max_temp=$2
    local avg_temp=$3
    local details=$4
    
    # Check if any notification channel is enabled
    if [ "$ENABLE_EMAIL" != "true" ] && \
       [ "$ENABLE_TELEGRAM" != "true" ] && \
       [ "$ENABLE_SLACK" != "true" ] && \
       [ "$ENABLE_PUSHOVER" != "true" ] && \
       [ "$USE_UNIFIED" != "true" ]; then
        logger -t temp_monitor "All notification channels disabled"
        return
    fi
    
    # Check cooldown
    if ! check_cooldown "$level"; then
        logger -t temp_monitor "Notification blocked by cooldown: $level"
        return
    fi
    
    local hostname=$(hostname)
    local timestamp=$(get_timestamp)
    
    # Build notification message
    local title="[$level] Temperature Alert - ${max_temp}°C"
    local message="������️ Temperature Alert: ${level}

Firewall: ${hostname}
Timestamp: ${timestamp}

������ Current Status:
  Maximum Temp:  ${max_temp}°C
  Average Temp:  ${avg_temp}°C

${details}

⚙️ Alert Thresholds:
  Warning:   ${TEMP_WARNING}°C
  Critical:  ${TEMP_CRITICAL}°C
  Emergency: ${TEMP_EMERGENCY}°C

������ Notification Channels: Email(${ENABLE_EMAIL}) Telegram(${ENABLE_TELEGRAM}) Slack(${ENABLE_SLACK}) Pushover(${ENABLE_PUSHOVER})"
    
    # Send notification
    send_notification "$title" "$message"
    
    # Update cooldown
    update_cooldown "$level"
}

# Trim log entries older than LOG_RETENTION_DAYS
# Log lines start with "YYYY-MM-DD", so a string comparison is chronological.
cleanup_logs() {
    [ -f "$LOG_FILE" ] || return 0
    local cutoff=$(date -v-${LOG_RETENTION_DAYS}d "+%Y-%m-%d")
    if awk -v cutoff="$cutoff" '$1 >= cutoff' "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null; then
        mv "${LOG_FILE}.tmp" "$LOG_FILE"
    else
        rm -f "${LOG_FILE}.tmp"
    fi
}

# Check pfSense notification configuration status
check_notification_config() {
    echo "Checking pfSense Notification Configuration..."
    echo "=============================================="
    echo ""
    
    /usr/local/bin/php << 'PHPEOF'
<?php
require_once('/etc/inc/config.inc');
global $config;

// Check Email/SMTP
if (isset($config['notifications']['smtp']['ipaddress']) && 
    $config['notifications']['smtp']['ipaddress'] != '') {
    echo "✓ Email (SMTP):  Configured (" . $config['notifications']['smtp']['ipaddress'] . ")\n";
} else {
    echo "✗ Email (SMTP):  NOT configured\n";
}

// Check Telegram
if (isset($config['notifications']['telegram']['api']) && 
    $config['notifications']['telegram']['api'] != '') {
    echo "✓ Telegram:      Configured\n";
} else {
    echo "✗ Telegram:      NOT configured\n";
}

// Check Slack
if (isset($config['notifications']['slack']['api']) && 
    $config['notifications']['slack']['api'] != '') {
    $channel = isset($config['notifications']['slack']['channel']) ? 
               $config['notifications']['slack']['channel'] : 'default';
    echo "✓ Slack:         Configured (channel: $channel)\n";
} else {
    echo "✗ Slack:         NOT configured\n";
}

// Check Pushover
if (isset($config['notifications']['pushover']['apikey']) && 
    $config['notifications']['pushover']['apikey'] != '') {
    echo "✓ Pushover:      Configured\n";
} else {
    echo "✗ Pushover:      NOT configured\n";
}
?>
PHPEOF
    
    echo ""
    echo "Script Configuration:"
    echo "---------------------"
    echo "Email enabled:    $ENABLE_EMAIL"
    echo "Telegram enabled: $ENABLE_TELEGRAM"
    echo "Slack enabled:    $ENABLE_SLACK"
    echo "Pushover enabled: $ENABLE_PUSHOVER"
    echo "Use unified:      $USE_UNIFIED"
}

##############################################################################
# MAIN MONITORING LOGIC
##############################################################################

main() {
    # Read the sensors once and derive both values from the same sample,
    # so MAX can never be lower than AVG
    TEMPS=$(get_cpu_temps)
    MAX_TEMP=$(echo "$TEMPS" | sort -rn | head -1 | cut -d'.' -f1)
    AVG_TEMP=$(echo "$TEMPS" | awk '{sum+=$1; count++} END {if (count > 0) printf "%.1f", sum/count}')
    CPU_FREQ=$(get_cpu_freq)
    
    # Validate temperature reading
    if [ -z "$MAX_TEMP" ] || [ "$MAX_TEMP" = "" ]; then
        logger -t temp_monitor "ERROR: Unable to read CPU temperature"
        exit 1
    fi
    
    # Log reading
    log_reading "$MAX_TEMP" "$AVG_TEMP" "$CPU_FREQ"
    
    # Get all core temps for detailed reporting
    CORE_TEMPS=$(sysctl dev.cpu | grep temperature | awk '{printf "  CPU%d: %s\n", NR-1, $2}')
    
    DETAILS="������ Core Temperatures:
${CORE_TEMPS}

������ CPU Info:
  Model: $(sysctl -n hw.model 2>/dev/null || echo "unknown")
  Frequency: ${CPU_FREQ} MHz"
    
    # Check thresholds and send notifications
    if [ "$MAX_TEMP" -ge "$TEMP_EMERGENCY" ]; then
        notify "EMERGENCY" "$MAX_TEMP" "$AVG_TEMP" "$DETAILS

⚠️⚠️⚠️ IMMEDIATE ACTION REQUIRED! ⚠️⚠️⚠️
CPU temperature in emergency range!
System may shutdown to prevent damage."
        
    elif [ "$MAX_TEMP" -ge "$TEMP_CRITICAL" ]; then
        notify "CRITICAL" "$MAX_TEMP" "$AVG_TEMP" "$DETAILS

⚠️ CRITICAL TEMPERATURE WARNING!
Check cooling system immediately.
Verify fans, airflow, and ambient temperature."
        
    elif [ "$MAX_TEMP" -ge "$TEMP_WARNING" ]; then
        notify "WARNING" "$MAX_TEMP" "$AVG_TEMP" "$DETAILS

⚠️ Temperature elevated above normal.
Monitor system closely.
Consider improving cooling if persistent."
        
    elif [ "$MAX_TEMP" -ge "$TEMP_INFO" ]; then
        logger -t temp_monitor "INFO: CPU temp ${MAX_TEMP}°C (above ${TEMP_INFO}°C info threshold)"
    fi
    
    # Trim old log entries once a day (the 03:00 cron run)
    if [ "$(date +%H%M)" = "0300" ]; then
        cleanup_logs
    fi
}

##############################################################################
# COMMAND LINE INTERFACE
##############################################################################

case "${1}" in
    --check-config)
        check_notification_config
        ;;
    --test)
        echo "Sending test notification to all enabled channels..."
        echo ""
        MAX_TEMP=$(get_max_temp)
        AVG_TEMP=$(get_avg_temp)
        CPU_FREQ=$(get_cpu_freq)
        
        send_notification "������ Test Alert" "This is a TEST notification from pfSense Temperature Monitor.

Current Status:
  Max Temp: ${MAX_TEMP}°C
  Avg Temp: ${AVG_TEMP}°C
  CPU Freq: ${CPU_FREQ} MHz

All enabled notification channels should receive this message.

Timestamp: $(get_timestamp)
Hostname: $(hostname)"
        
        echo ""
        echo "Test notification sent!"
        echo "Check: Email, Telegram, Slack, Pushover"
        echo "Also check: System → Notifications in pfSense GUI"
        ;;
    --status)
        echo "Current Temperature Status"
        echo "=========================="
        echo "Timestamp: $(get_timestamp)"
        echo ""
        sysctl dev.cpu | grep temperature
        echo ""
        echo "Maximum: $(get_max_temp)°C"
        echo "Average: $(get_avg_temp)°C"
        echo "Frequency: $(get_cpu_freq) MHz"
        echo ""
        echo "Thresholds:"
        echo "  Info:      ${TEMP_INFO}°C"
        echo "  Warning:   ${TEMP_WARNING}°C"
        echo "  Critical:  ${TEMP_CRITICAL}°C"
        echo "  Emergency: ${TEMP_EMERGENCY}°C"
        ;;
    --log)
        if [ -f "$LOG_FILE" ]; then
            tail -20 "$LOG_FILE"
        else
            echo "Log file not found: $LOG_FILE"
        fi
        ;;
    *)
        main
        ;;
esac