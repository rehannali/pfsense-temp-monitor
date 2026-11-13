#!/bin/sh
#
# Real-time Temperature Dashboard for pfSense
# Press Ctrl+C to exit
#

REFRESH_INTERVAL=2

while true; do
    clear
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║       pfSense Temperature Monitor - Live Dashboard          ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Hostname:  $(hostname)"
    echo "Uptime:    $(uptime | awk '{print $3,$4}' | sed 's/,//')"
    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo "CPU Core Temperatures"
    echo "══════════════════════════════════════════════════════════════"
    
    # Display each core with status indicator
    sysctl dev.cpu | grep temperature | while read line; do
        core=$(echo "$line" | grep -oE "dev.cpu.[0-9]" | grep -oE "[0-9]")
        temp=$(echo "$line" | awk -F': ' '{print $2}')
        temp_num=$(echo "$temp" | cut -d'.' -f1 | sed 's/C//')
        
        # Status indicator based on temperature
        if [ "$temp_num" -lt 50 ]; then
            status="✓ EXCELLENT"
            bar="████████████████████"
        elif [ "$temp_num" -lt 60 ]; then
            status="○ GOOD    "
            bar="██████████████░░░░░░"
        elif [ "$temp_num" -lt 70 ]; then
            status="△ WARM    "
            bar="████████████░░░░░░░░"
        elif [ "$temp_num" -lt 80 ]; then
            status="⚠ HOT     "
            bar="████████░░░░░░░░░░░░"
        else
            status="✗ CRITICAL"
            bar="████░░░░░░░░░░░░░░░░"
        fi
        
        printf "  Core %d: %7s  [%s] %s\n" "$core" "$temp" "$bar" "$status"
    done
    
    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo "Statistics"
    echo "══════════════════════════════════════════════════════════════"
    
    MAX=$(sysctl dev.cpu | grep temperature | awk -F': ' '{print $2}' | sed 's/C//' | sort -rn | head -1)
    MIN=$(sysctl dev.cpu | grep temperature | awk -F': ' '{print $2}' | sed 's/C//' | sort -n | head -1)
    AVG=$(sysctl dev.cpu | grep temperature | awk -F': ' '{print $2}' | sed 's/C//' | awk '{sum+=$1; count++} END {printf "%.1f", sum/count}')
    FREQ=$(sysctl -n dev.cpu.0.freq 2>/dev/null || echo "N/A")
    
    printf "  Maximum:     %.1f°C\n" "$MAX"
    printf "  Minimum:     %.1f°C\n" "$MIN"
    printf "  Average:     %.1f°C\n" "$AVG"
    printf "  CPU Freq:    %s MHz\n" "$FREQ"
    
    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo "Thermal Zones"
    echo "══════════════════════════════════════════════════════════════"
    
    TZ_TEMP=$(sysctl -n hw.acpi.thermal.tz0.temperature 2>/dev/null || echo "N/A")
    TZ_CRIT=$(sysctl -n hw.acpi.thermal.tz0._CRT 2>/dev/null || echo "N/A")
    TZ_HOT=$(sysctl -n hw.acpi.thermal.tz0._HOT 2>/dev/null || echo "N/A")
    
    printf "  ACPI TZ0:    %s\n" "$TZ_TEMP"
    printf "  Critical:    %s\n" "$TZ_CRIT"
    if [ "$TZ_HOT" != "N/A" ] && [ "$TZ_HOT" != "-1" ]; then
        printf "  Hot:         %s\n" "$TZ_HOT"
    fi
    
    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo "Press Ctrl+C to exit | Refreshing every ${REFRESH_INTERVAL}s"
    echo "══════════════════════════════════════════════════════════════"
    
    sleep $REFRESH_INTERVAL
done