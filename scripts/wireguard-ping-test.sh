#!/bin/bash

# This script extracts endpoints from WireGuard configuration files in a specified directory,
# tests each endpoint using mtr (3 cycles) to measure average latency, and prints a sorted summary of the results.

# --- Usage ---
# ./scripts/wireguard-ping-test.sh /path/to/your/wireguard/configs [--sort avg|stdev]
#
# Make sure to make the script executable first:
# chmod +x ./scripts/wireguard-ping-test.sh

SORT_BY="avg"
CONFIG_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sort)
      if [[ "$2" != "avg" && "$2" != "stdev" ]]; then
        echo "Error: --sort must be 'avg' or 'stdev'."
        exit 1
      fi
      SORT_BY="$2"
      shift 2
      ;;
    *)
      CONFIG_DIR="$1"
      shift
      ;;
  esac
done

if [ -z "$CONFIG_DIR" ]; then
  echo "Usage: $0 <wireguard_configs_directory> [--sort avg|stdev]"
  exit 1
fi

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

MAX_JOBS=50

# Check if the provided path is a valid directory.
if [ ! -d "$CONFIG_DIR" ]; then
  echo "Error: Directory '$CONFIG_DIR' not found."
  exit 1
fi

echo "╔══════════════════════════════════════════════╗"
echo "║        WireGuard Endpoint Ping Tester        ║"
echo "╚══════════════════════════════════════════════╝"
echo
echo "  Directory : $CONFIG_DIR"
echo "  Parallel  : $MAX_JOBS jobs at a time  (3 mtr cycles each)"
echo "  Sort by   : $SORT_BY"
echo
echo "Scanning for endpoints..."
echo

ping_endpoint() {
  local endpoint="$1"
  local conf_file="$2"
  local domain
  local filename
  local host="$endpoint"
  local is_ipv6=0

  filename="$(basename "$conf_file")"

  # Strip brackets for IPv6 like [2001:db8::1] and mark as IPv6
  if [[ "$host" == \[*\] ]]; then
    host="${host#[}"
    host="${host%]}"
    is_ipv6=1
  fi

  if [[ "$host" =~ ^[0-9.]+$ || "$host" == *:* ]]; then
    domain="-"
  else
    domain="$host"
  fi

  echo "Testing endpoint: $endpoint (from $(basename "$conf_file"))..."

  # Run mtr: 3 cycles, report mode, skip DNS for intermediate hops. Force -6 for IPv6.
  if [ $is_ipv6 -eq 1 ]; then
    mtr_output=$(mtr -6 --report --report-cycles 3 --no-dns "$host" 2>/dev/null)
  else
    mtr_output=$(mtr --report --report-cycles 3 --no-dns "$host" 2>/dev/null)
  fi

  # Last line of mtr report is the target host: fields are index, host, Loss%, Snt, Last, Avg, Best, Wrst, StDev
  last_line=$(echo "$mtr_output" | tail -1)
  loss=$(echo "$last_line" | awk '{print $3}')
  avg_ms=$(echo "$last_line" | awk '{print $6}')
  stdev_ms=$(echo "$last_line" | awk '{print $9}')

  if [ -n "$avg_ms" ] && [ "$loss" != "100.0%" ]; then
    echo "  => Success — avg: ${avg_ms} ms, stdev: ${stdev_ms} ms"
    printf "%s\t%s\t%s\t%s\t%s\n" "$avg_ms" "$stdev_ms" "$filename" "$domain" "$host" >> "$TMPFILE"
  else
    echo "  => Failed: Host unreachable or request timed out."
    printf "%s\t%s\t%s\t%s\t%s\n" "99999" "9999" "$filename" "$domain" "$host (Failed)" >> "$TMPFILE"
  fi
  echo
}

# Loop through all .conf files in the specified directory.
for conf_file in "$CONFIG_DIR"/*.conf; do
  # Ensure it's a file before processing.
  if [ -f "$conf_file" ]; then
    # Extract one or more endpoint hosts from lines like:
    #   Endpoint = host:port
    # Supports host being a domain, IPv4, or bracketed IPv6 like [2001:db8::1]
    mapfile -t endpoints < <(grep -oP 'Endpoint\s*=\s*\K(\[[^\]]+\]|[^:\s]+)' "$conf_file")

    for endpoint in "${endpoints[@]}"; do
      if [ -n "$endpoint" ]; then
        # Throttle to MAX_JOBS concurrent background jobs.
        while [ "$(jobs -rp | wc -l)" -ge "$MAX_JOBS" ]; do
          sleep 0.1
        done
        ping_endpoint "$endpoint" "$conf_file" &
      fi
    done
  fi
done

# Wait for all remaining background jobs to finish.
wait

printf '┌%*s┐\n' 122 '' | sed 's/ /─/g'
printf "│ %-120s │\n" "MTR Summary (sorted by: $SORT_BY)"
echo "├────────────┬────────────┬──────────────────────────────┬──────────────────────────────┬──────────────────────────────────┤"
printf "│ %-10s │ %-10s │ %-28s │ %-28s │ %-32s │\n" "Avg (ms)" "StDev (ms)" "Filename" "Domain" "Endpoint"
echo "├────────────┼────────────┼──────────────────────────────┼──────────────────────────────┼──────────────────────────────────┤"

# Sort by selected key (primary), with the other as tiebreaker.
if [ "$SORT_BY" = "stdev" ]; then
  sort -t $'\t' -k2,2n -k1,1n "$TMPFILE"
else
  sort -t $'\t' -k1,1n -k2,2n "$TMPFILE"
fi | while IFS=$'\t' read -r avg stdev filename domain endpoint; do
  printf "│ %-10s │ %-10s │ %-28s │ %-28s │ %-32s │\n" "$avg" "$stdev" "$filename" "$domain" "$endpoint"
done

echo "└────────────┴────────────┴──────────────────────────────┴──────────────────────────────┴──────────────────────────────────┘"
