#!/bin/bash

# This script extracts endpoints from WireGuard configuration files in a specified directory,
# pings each endpoint (3 packets) to measure average latency, and then prints a sorted summary of the results.

# --- Usage ---
# ./scripts/wireguard-ping-test.sh /path/to/your/wireguard/configs
#
# Make sure to make the script executable first:
# chmod +x ./scripts/wireguard-ping-test.sh

# Check if a directory argument is provided.
if [ -z "$1" ]; then
  echo "Usage: $0 <wireguard_configs_directory>"
  echo "Please provide the path to the directory containing your WireGuard .conf files."
  exit 1
fi

CONFIG_DIR=$1
RESULTS=()

# Check if the provided path is a valid directory.
if [ ! -d "$CONFIG_DIR" ]; then
  echo "Error: Directory '$CONFIG_DIR' not found."
  exit 1
fi

echo "Scanning for WireGuard endpoints in '$CONFIG_DIR'..."
echo

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
        host="$endpoint"
        is_ipv6=0
        # Strip brackets for IPv6 like [2001:db8::1] and mark as IPv6
        if [[ "$host" == \[*\] ]]; then
          host="${host#[}"
          host="${host%]}"
          is_ipv6=1
        fi

        echo "Pinging endpoint: $endpoint (from $(basename \"$conf_file\"))..."

        # Build ping command: 3 packets, quiet summary. Force -6 when the endpoint is IPv6.
        if [ $is_ipv6 -eq 1 ]; then
          ping_output=$(ping -6 -c 3 -q "$host" 2>/dev/null)
        else
          ping_output=$(ping -c 3 -q "$host" 2>/dev/null)
        fi

        # Extract the min/avg/max[/mdev] block and take the second (avg) value.
        numbers=$(echo "$ping_output" | grep -Eo '[0-9.]+/[0-9.]+/[0-9.]+(/[0-9.]+)?' | head -n1)
        if [ -n "$numbers" ]; then
          avg_ms=$(echo "$numbers" | cut -d'/' -f2)
          echo "  => Success (avg of 3): ${avg_ms} ms"
          RESULTS+=("$avg_ms $host")
        else
          echo "  => Failed: Host unreachable or request timed out."
          RESULTS+=("99999 $host (Failed)")
        fi
        echo
      fi
    done
  fi
done

echo "--- Ping Summary ---"
echo "Sorted by lowest average ping (ms) to highest."
echo "---------------------------------------"
printf "%-10s | %s\n" "Avg (ms)" "Endpoint"
echo "---------------------------------------"

# Sort the results numerically based on the ping time and print them in a table format.
# The subshell with the for loop ensures that the `sort` command receives all the data.
(
  for result in "${RESULTS[@]}"; do
    echo "$result"
  done
) | sort -n | while read -r time host extra; do
  # Print the formatted line. The `extra` variable captures any additional text like "(Failed)".
  printf "%-10s | %s %s\n" "$time" "$host" "$extra"
done

echo "---------------------------------------"
echo "Script finished."
