#!/bin/sh
#
# Temperature Report Generator for pfSense
# Fully automated - no interactive prompts
# Exit codes: 0=success, 1=no data, 2=error
#

##############################################################################
# CONFIGURATION
##############################################################################

LOG_FILE="/var/log/temperature_monitor.log"
REPORT_TYPE="${1:-daily}"
AUTO_SEND="${2:-no}"  # Set to "yes" to auto-send, otherwise display only

# Notification settings
ENABLE_EMAIL=true
ENABLE_TELEGRAM=true
ENABLE_SLACK=true
ENABLE_PUSHOVER=true

# Optional overrides shared with temp_monitor.sh (LOG_FILE, ENABLE_* toggles)
CONF_FILE="/usr/local/etc/temp_monitor.conf"
[ -f "$CONF_FILE" ] && . "$CONF_FILE"

##############################################################################
# FUNCTIONS
##############################################################################

get_date_range() {
    case $REPORT_TYPE in
        daily)
            # Rolling window: the last 24 hours, compared by full timestamp
            START_DATE=$(date -v-24H "+%Y-%m-%d %H:%M:%S")
            END_DATE=$(date "+%Y-%m-%d %H:%M:%S")
            TITLE="Daily Temperature Report"
            ;;
        weekly)
            START_DATE=$(date -v-7d "+%Y-%m-%d")
            END_DATE=$(date "+%Y-%m-%d")
            TITLE="Weekly Temperature Report"
            ;;
        monthly)
            START_DATE=$(date -v-30d "+%Y-%m-%d")
            END_DATE=$(date "+%Y-%m-%d")
            TITLE="Monthly Temperature Report"
            ;;
        *)
            echo "ERROR: Invalid report type. Use: daily, weekly, or monthly" >&2
            exit 2
            ;;
    esac
}

generate_report() {
    local report_text=""

    report_text="${report_text}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  $TITLE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Hostname: $(hostname)
Period:   From $START_DATE to $END_DATE
Generated: $(date '+%Y-%m-%d %H:%M:%S')
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

"

    if [ ! -f "$LOG_FILE" ]; then
        echo "ERROR: Log file not found: $LOG_FILE" >&2
        return 1
    fi

    # Extract data for period
    case $REPORT_TYPE in
        daily)
            # Compare "YYYY-MM-DD HH:MM:SS" as a string: sorts chronologically
            DATA=$(awk -v start="$START_DATE" '($1 " " $2) >= start' "$LOG_FILE" 2>/dev/null)
            ;;
        weekly|monthly)
            DATA=$(awk -v start="$START_DATE" '$1 >= start' "$LOG_FILE" 2>/dev/null)
            ;;
    esac

    if [ -z "$DATA" ]; then
        echo "ERROR: No data found for period starting $START_DATE" >&2
        return 1
    fi

    # Calculate MAX, MIN, AVG, COUNT in a single awk pass — avoids sort|head broken pipe
    STATS=$(echo "$DATA" | grep -oE "MAX: [0-9]+°C" | grep -oE "[0-9]+" | \
        awk 'BEGIN { max=-999; min=9999; sum=0; count=0 }
             {
                 v = $1 + 0
                 if (v > max) max = v
                 if (v < min) min = v
                 sum += v
                 count++
             }
             END {
                 if (count > 0)
                     printf "%d %d %.1f %d", max, min, sum/count, count
             }')

    MAX=$(echo "$STATS" | awk '{print $1}')
    MIN=$(echo "$STATS" | awk '{print $2}')
    AVG=$(echo "$STATS" | awk '{print $3}')
    COUNT=$(echo "$STATS" | awk '{print $4}')

    # Validate data
    if [ -z "$MAX" ] || [ -z "$MIN" ] || [ -z "$AVG" ]; then
        echo "ERROR: Failed to parse temperature data" >&2
        return 1
    fi

    report_text="${report_text}🌡 Temperature Statistics
─────────────────────────────────────────────
  Maximum Temperature: ${MAX}°C
  Minimum Temperature: ${MIN}°C
  Average Temperature: ${AVG}°C
  Total Readings:      ${COUNT}

"

    # Temperature distribution
    DISTRIBUTION=$(echo "$DATA" | grep -oE "MAX: [0-9]+°C" | grep -oE "[0-9]+" | \
        awk '{
            v = $1 + 0
            if (v < 40) cool++
            else if (v < 50) normal++
            else if (v < 60) warm++
            else if (v < 70) hot++
            else critical++
            total++
        }
        END {
            if (total > 0) {
                printf "  < 40\xc2\xb0C (Cool):     %4d readings (%.1f%%)\n", cool+0,   (cool+0)/total*100
                printf "  40-49\xc2\xb0C (Normal):  %4d readings (%.1f%%)\n", normal+0, (normal+0)/total*100
                printf "  50-59\xc2\xb0C (Warm):    %4d readings (%.1f%%)\n", warm+0,   (warm+0)/total*100
                printf "  60-69\xc2\xb0C (Hot):     %4d readings (%.1f%%)\n", hot+0,    (hot+0)/total*100
                printf "  >=70\xc2\xb0C (Critical): %4d readings (%.1f%%)\n", critical+0, (critical+0)/total*100
            }
        }')

    report_text="${report_text}📊 Temperature Distribution
─────────────────────────────────────────────
${DISTRIBUTION}

"

    # Peak temperatures - different approach per report type
    case $REPORT_TYPE in
        daily)
            # Peak temperature per hour. The 24h window spans two dates, so
            # the key is "date hour" to keep yesterday and today separate.
            # Log line fields: $1=date $2=time $3="|" $4="MAX:" $5="NN°C"
            HOURLY=$(echo "$DATA" | awk '{
                    split($2, t, ":")
                    k = $1 " " t[1]
                    v = $5 + 0
                    if (!(k in max) || v > max[k]) max[k] = v
                }
                END {
                    for (k in max)
                        printf "  %s:00 - Peak: %d\xc2\xb0C\n", k, max[k]
                }' | sort)

            if [ -n "$HOURLY" ]; then
                report_text="${report_text}⏰ Peak Temperatures by Hour
─────────────────────────────────────────────
${HOURLY}

"
            fi
            ;;

        weekly|monthly)
            # Top 15 highest temperature events
            # awk NR<=15 consumes all of sort's output — no broken pipe
            TOP_PEAKS=$(echo "$DATA" | \
                grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}.*MAX: [0-9]+" | \
                sed 's/^\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]\):[0-9][0-9].*MAX: \([0-9][0-9]*\).*/\2 \1/' | \
                sort -rn | \
                awk 'NR <= 15 { printf "  %s %s - %d\xc2\xb0C\n", $2, $3, $1 }')

            if [ -n "$TOP_PEAKS" ]; then
                report_text="${report_text}🔥 Top 15 Highest Temperature Events
─────────────────────────────────────────────
${TOP_PEAKS}

"
            fi

            # Daily peak temperatures
            DAILY_PEAKS=$(echo "$DATA" | \
                grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2}.*MAX: [0-9]+" | \
                sed 's/^\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\).*MAX: \([0-9][0-9]*\).*/\1 \2/' | \
                awk '{
                    d = $1
                    v = $2 + 0
                    if (v > max[d]) max[d] = v
                }
                END {
                    for (d in max)
                        printf "  %s - Peak: %d\xc2\xb0C\n", d, max[d]
                }' | sort)

            if [ -n "$DAILY_PEAKS" ]; then
                report_text="${report_text}📅 Daily Peak Temperatures
─────────────────────────────────────────────
${DAILY_PEAKS}

"
            fi
            ;;
    esac

    # Health assessment
    if [ "$MAX" -lt 50 ]; then
        HEALTH="✓ EXCELLENT - All temperatures in optimal range"
    elif [ "$MAX" -lt 60 ]; then
        HEALTH="✓ GOOD - Temperatures normal"
    elif [ "$MAX" -lt 70 ]; then
        HEALTH="⚠ FAIR - Some elevated temperatures detected"
    elif [ "$MAX" -lt 80 ]; then
        HEALTH="⚠ WARNING - High temperatures detected"
    else
        HEALTH="❌ CRITICAL - Dangerous temperatures detected!"
    fi

    report_text="${report_text}💊 System Health Assessment
─────────────────────────────────────────────
  Status: ${HEALTH}
  Max Observed: ${MAX}°C
  Avg Observed: ${AVG}°C

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    echo "$report_text"
    return 0
}

send_report_to_channels() {
    local title=$1
    local report=$2

    # Validate input
    if [ -z "$report" ]; then
        logger -t temp_report "ERROR: Cannot send empty report"
        return 1
    fi

    # Escape for PHP
    local escaped_title=$(echo "$title" | sed "s/'/\\\'/g" | sed 's/"/\\"/g')
    local escaped_report=$(echo "$report" | sed "s/'/\\\'/g" | sed 's/"/\\"/g')

    # Send via PHP with timeout protection
    timeout 30 /usr/local/bin/php << PHPEOF 2>/dev/null
<?php
require_once('/etc/inc/globals.inc');
require_once('/etc/inc/config.inc');
require_once('/etc/inc/notices.inc');

\$title = '${escaped_title}';
\$message = '${escaped_report}';
\$channels_sent = array();
\$errors = array();

// Email (SMTP)
if ('${ENABLE_EMAIL}' === 'true') {
    try {
        notify_via_smtp(\$message, true, \$title);
        \$channels_sent[] = 'Email';
    } catch (Exception \$e) {
        \$errors[] = 'Email: ' . \$e->getMessage();
    }
}

// Telegram
if ('${ENABLE_TELEGRAM}' === 'true') {
    try {
        notify_via_telegram(\$message, true);
        \$channels_sent[] = 'Telegram';
    } catch (Exception \$e) {
        \$errors[] = 'Telegram: ' . \$e->getMessage();
    }
}

// Slack
if ('${ENABLE_SLACK}' === 'true') {
    try {
        notify_via_slack(\$message, true);
        \$channels_sent[] = 'Slack';
    } catch (Exception \$e) {
        \$errors[] = 'Slack: ' . \$e->getMessage();
    }
}

// Pushover
if ('${ENABLE_PUSHOVER}' === 'true') {
    try {
        notify_via_pushover(\$message, true);
        \$channels_sent[] = 'Pushover';
    } catch (Exception \$e) {
        \$errors[] = 'Pushover: ' . \$e->getMessage();
    }
}

// Create notice in pfSense GUI
file_notice('temp_report', \$message, \$title, '');

// Log results
if (count(\$channels_sent) > 0) {
    log_error("Temperature Report: Sent successfully via " . implode(', ', \$channels_sent));
    echo "SUCCESS: Sent via " . implode(', ', \$channels_sent) . "\n";
    exit(0);
} else {
    log_error("Temperature Report: Failed to send - " . implode('; ', \$errors));
    echo "ERROR: Failed to send report\n";
    exit(1);
}
?>
PHPEOF

    return $?
}

##############################################################################
# MAIN
##############################################################################

# Parse command line
case "$1" in
    daily|weekly|monthly)
        REPORT_TYPE="$1"
        ;;
    --help|-h)
        echo "Usage: $0 {daily|weekly|monthly} [--send]"
        echo ""
        echo "Options:"
        echo "  daily         Generate daily report (last 24 hours)"
        echo "  weekly        Generate weekly report (last 7 days)"
        echo "  monthly       Generate monthly report (last 30 days)"
        echo "  --send        Automatically send to all configured channels"
        echo ""
        echo "Examples:"
        echo "  $0 daily                # Display report only"
        echo "  $0 daily --send         # Generate and send report"
        echo "  $0 weekly --send        # Generate and send weekly report"
        exit 0
        ;;
    *)
        echo "ERROR: Invalid argument. Use --help for usage information." >&2
        exit 2
        ;;
esac

# Check if auto-send is requested
if [ "$2" = "--send" ] || [ "$2" = "-s" ]; then
    AUTO_SEND="yes"
fi

# Get date range
get_date_range

# Generate report. stderr is NOT captured, so the specific error
# (e.g. "No data found for period starting ...") prints to the terminal.
REPORT=$(generate_report)
REPORT_STATUS=$?

# Check if report generation was successful
if [ $REPORT_STATUS -ne 0 ]; then
    echo "ERROR: Failed to generate $REPORT_TYPE report" >&2
    logger -t temp_report "ERROR: Failed to generate $REPORT_TYPE report"
    exit 1
fi

# Validate report content
if [ -z "$REPORT" ]; then
    echo "ERROR: Generated report is empty" >&2
    logger -t temp_report "ERROR: Generated empty $REPORT_TYPE report"
    exit 1
fi

# Display report
echo "$REPORT"

# Send to channels if requested
if [ "$AUTO_SEND" = "yes" ]; then
    echo ""
    echo "Sending report to notification channels..."

    if send_report_to_channels "🌡 $TITLE" "$REPORT"; then
        echo "✓ Report sent successfully!"
        logger -t temp_report "SUCCESS: $REPORT_TYPE report sent to all channels"
        exit 0
    else
        echo "✗ Failed to send report" >&2
        logger -t temp_report "ERROR: Failed to send $REPORT_TYPE report"
        exit 1
    fi
else
    logger -t temp_report "INFO: $REPORT_TYPE report generated (display only)"
    exit 0
fi
