#!/bin/bash

# Configuration for ping
PING_COUNT=4      # Number of ping packets to send
PING_TIMEOUT=2    # Timeout in seconds per packet (-W option for Linux ping)

# Function to display usage
usage() {
  echo "Usage: $0 <path_to_wireguard_config_folder>"
  echo "Example: $0 ./wireguard_configs"
  exit 1
}

# Check if a folder path is provided
if [ -z "$1" ]; then
  usage
fi

CONFIG_FOLDER="$1"

# Check if the provided path is a directory
if [ ! -d "$CONFIG_FOLDER" ]; then
  echo "Error: Folder '$CONFIG_FOLDER' not found or is not a directory."
  usage
fi

echo "Pinging WireGuard Endpoints from '$CONFIG_FOLDER':"
echo "----------------------------------------------------"

# Find all files ending with .conf in the specified folder
# and iterate through them
find "$CONFIG_FOLDER" -type f -name "*.conf" | while IFS= read -r config_file; do
  # Extract just the filename for cleaner output
  filename=$(basename "$config_file")

  # Initialize endpoint variable for each file
  endpoint=""

  # Use awk to specifically find the Endpoint line within the [Peer] section.
  # This makes it more robust.
  # Then pipe to tr -d '\r' to remove Windows carriage returns,
  # and finally to sed to remove the "Endpoint = " prefix and the ":port" suffix.
  extracted_line=$(awk '/^\[Peer\]/{flag=1; next} /^\[/{flag=0} flag && /^Endpoint = /{print; exit}' "$config_file")

  if [ -n "$extracted_line" ]; then
    # Remove potential Windows carriage returns, then "Endpoint = ", then ":port"
    # Using [0-9]\+ to ensure at least one digit is present for the port
    endpoint=$(echo "$extracted_line" | tr -d '\r' | sed -e 's/^Endpoint = //g' -e 's/:[0-9]\+$//g')
  fi

  # Output the filename and endpoint for context
  echo -n "$filename ($endpoint): "

  # Check if an endpoint was found and processed correctly
  if [ -z "$endpoint" ]; then
    echo "No 'Endpoint' found in [Peer] section or extraction failed."
    continue # Move to the next file
  fi

  # Validate that the port removal was successful
  if echo "$endpoint" | grep -q ':'; then
    echo "Error: Endpoint still contains a port (e.g., $endpoint). Skipping ping."
    continue # Move to the next file
  fi

  # Ping the endpoint
  # -c $PING_COUNT: send N packets
  # -W $PING_TIMEOUT: wait N seconds for a response (Linux specific)
  # -4: Force IPv4 (optional, but can be useful if endpoint resolves to IPv6)
  # 2>/dev/null: Suppress ping error messages (e.g., "unknown host")
  ping_output=$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" -4 "$endpoint" 2>/dev/null)

  # Extract average latency from ping output (Linux format)
  # This specifically looks for the "rtt min/avg/max/mdev" line
  avg_latency=$(echo "$ping_output" | grep "rtt min/avg/max/mdev" | awk '{print $4}' | cut -d'/' -f2)

  if [ -n "$avg_latency" ]; then
    echo "Avg. Ping: ${avg_latency} ms"
  else
    # If no average latency, check for packet loss
    packet_loss=$(echo "$ping_output" | grep "packet loss" | awk '{print $6}' | sed 's/%//')
    if [ -n "$packet_loss" ] && [ "$packet_loss" -eq 100 ]; then
      echo "Host Unreachable (100% loss)"
    elif [ -n "$packet_loss" ]; then
      echo "Ping failed (Packet loss: ${packet_loss}%)"
    else
      echo "Ping failed (No summary output or host unreachable)."
    fi
  fi
done

echo "----------------------------------------------------"
