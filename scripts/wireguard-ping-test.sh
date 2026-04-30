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

MAX_JOBS=5

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
echo "  Parallel  : $MAX_JOBS jobs at a time  (3 ping packets each)"
echo "  Sort by   : $SORT_BY"
echo
echo "Scanning for endpoints..."
echo

ping_endpoint() {
  local endpoint="$1"
  local conf_file="$2"
  local host="$endpoint"
  local is_ipv6=0

  # Strip brackets for IPv6 like [2001:db8::1] and mark as IPv6
  if [[ "$host" == \[*\] ]]; then
    host="${host#[}"
    host="${host%]}"
    is_ipv6=1
  fi

  echo "Testing endpoint: $endpoint (from $(basename "$conf_file"))..."

  local ping_cmd="ping"
  if [ "$is_ipv6" -eq 1 ] && command -v ping6 >/dev/null 2>&1; then
    ping_cmd="ping6"
  fi

  # Run ping: 3 packets
  ping_output=$($ping_cmd -c 3 "$host" 2>/dev/null)

  # Extract stats from the last line (e.g. round-trip min/avg/max/stddev = 24.322/25.032/26.030/0.726 ms)
  stats_line=$(echo "$ping_output" | tail -1)
  if [[ "$stats_line" =~ (rtt|round-trip) ]]; then
    avg_ms=$(echo "$stats_line" | awk -F'[/= ]+' '{print $7}')
    stdev_ms=$(echo "$stats_line" | awk -F'[/= ]+' '{print $9}')
  else
    avg_ms=""
    stdev_ms=""
  fi

  if [ -n "$avg_ms" ]; then
    echo "  => Success — avg: ${avg_ms} ms, stdev: ${stdev_ms} ms"
    echo "$avg_ms $stdev_ms $host" >> "$TMPFILE"
  else
    echo "  => Failed: Host unreachable or request timed out."
    echo "99999 9999 $host (Failed)" >> "$TMPFILE"
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
    endpoints=$(awk '/^[ \t]*Endpoint[ \t]*=/ {
      sub(/^[ \t]*Endpoint[ \t]*=[ \t]*/, "")
      if ($0 ~ /^\[/) {
        sub(/\].*/, "]")
      } else {
        sub(/:.*/, "")
      }
      print
    }' "$conf_file")

    for endpoint in $endpoints; do
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

echo "┌────────────────────────────────────────────────────────────┐"
printf "│           Ping Summary  (sorted by: %-22s│\n" "$SORT_BY)"
echo "├────────────┬────────────┬──────────────────────────────────┤"
printf "│ %-10s │ %-10s │ %-32s │\n" "Avg (ms)" "StDev (ms)" "Endpoint"
echo "├────────────┼────────────┼──────────────────────────────────┤"

# Sort by selected key (primary), with the other as tiebreaker.
if [ "$SORT_BY" = "stdev" ]; then
  sort_cmd="sort -k2,2n -k1,1n"
else
  sort_cmd="sort -k1,1n -k2,2n"
fi
$sort_cmd "$TMPFILE" | while read -r avg stdev host extra; do
  label="$host${extra:+ $extra}"
  printf "│ %-10s │ %-10s │ %-32s │\n" "$avg" "$stdev" "$label"
done

echo "└────────────┴────────────┴──────────────────────────────────┘"
