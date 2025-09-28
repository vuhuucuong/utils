#!/bin/bash

set -o errexit  # Exit on error
set -o nounset  # Exit on undefined variable
set -o pipefail # Exit if any command in a pipe fails

# Configuration
readonly PING_COUNT=4      # Number of ping packets to send
readonly PING_TIMEOUT=2    # Timeout in seconds per packet
readonly SCRIPT_NAME=$(basename "$0")
readonly SEPARATOR="----------------------------------------------------"

# Error codes
readonly ERROR_NO_ARGS=1
readonly ERROR_INVALID_DIR=2
readonly ERROR_NO_CONFIGS=3

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Function to display error messages
error() {
    echo -e "${RED}Error: $1${NC}" >&2
}

# Function to display success messages
success() {
    echo -e "${GREEN}$1${NC}"
}

# Function to display warning messages
warning() {
    echo -e "${YELLOW}Warning: $1${NC}"
}

# Function to display usage information
usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <path_to_wireguard_config_folder>
Tests ping connectivity to WireGuard endpoints defined in configuration files.

Arguments:
    path_to_wireguard_config_folder    Directory containing WireGuard .conf files

Example: 
    ${SCRIPT_NAME} ./wireguard_configs
EOF
    exit "${1:-$ERROR_NO_ARGS}"
}

# Function to validate input arguments
validate_input() {
    local config_dir=$1

    if [ -z "$config_dir" ]; then
        error "No directory path provided."
        usage "$ERROR_NO_ARGS"
    fi

    if [ ! -d "$config_dir" ]; then
        error "Directory '$config_dir' not found or is not a directory."
        usage "$ERROR_INVALID_DIR"
    fi

    # Check if there are any .conf files
    if ! find "$config_dir" -type f -name "*.conf" -print -quit | grep -q .; then
        error "No .conf files found in '$config_dir'."
        exit "$ERROR_NO_CONFIGS"
    fi
}

# Cleanup function
cleanup() {
    # Add any cleanup tasks here
    exit "${1:-0}"
}

# Set up trap for cleanup
trap 'cleanup $?' EXIT
trap 'cleanup 1' INT TERM

# Validate input arguments
validate_input "${1:-}"

CONFIG_FOLDER="$1"

# Function to extract endpoint from WireGuard config file
extract_endpoint() {
    local config_file=$1
    local extracted_line
    local endpoint=""

    # Extract endpoint from [Peer] section
    extracted_line=$(awk '/^\[Peer\]/{flag=1; next} /^\[/{flag=0} flag && /^Endpoint = /{print; exit}' "$config_file")

    if [ -n "$extracted_line" ]; then
        # Clean up the endpoint string
        endpoint=$(echo "$extracted_line" | tr -d '\r' | sed -e 's/^Endpoint = //g' -e 's/:[0-9]\+$//g')
    fi

    echo "$endpoint"
}

# Function to test ping to an endpoint
test_ping() {
    local endpoint=$1
    local ping_output
    local avg_latency
    local packet_loss

    ping_output=$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" -4 "$endpoint" 2>/dev/null)
    
    # Extract average latency
    avg_latency=$(echo "$ping_output" | grep "rtt min/avg/max/mdev" | awk '{print $4}' | cut -d'/' -f2)
    
    if [ -n "$avg_latency" ]; then
        success "Avg. Ping: ${avg_latency} ms"
        return 0
    fi

    # Check for packet loss if no average latency
    packet_loss=$(echo "$ping_output" | grep "packet loss" | awk '{print $6}' | sed 's/%//')
    if [ -n "$packet_loss" ] && [ "$packet_loss" -eq 100 ]; then
        error "Host Unreachable (100% loss)"
    elif [ -n "$packet_loss" ]; then
        warning "Ping failed (Packet loss: ${packet_loss}%)"
    else
        error "Ping failed (No summary output or host unreachable)."
    fi
    return 1
}

# Function to format latency for sorting
format_latency() {
    local latency=$1
    if [ -z "$latency" ]; then
        echo "999999.999" # High value for failed pings
    else
        echo "$latency"
    fi
}

# Temporary file for results
RESULTS_FILE=$(mktemp)

# Add cleanup of temp file
trap 'rm -f "$RESULTS_FILE"; cleanup $?' EXIT

echo "Testing WireGuard endpoints from '$CONFIG_FOLDER'..."
echo "$SEPARATOR"
printf "%-30s %-30s %-15s %s\n" "CONFIG FILE" "ENDPOINT" "STATUS" "LATENCY"
echo "$SEPARATOR"

# Process each WireGuard config file and collect results
find "$CONFIG_FOLDER" -type f -name "*.conf" | while IFS= read -r config_file; do
    filename=$(basename "$config_file")
    endpoint=$(extract_endpoint "$config_file")
    status="Unknown"
    latency=""

    # Validate endpoint
    if [ -z "$endpoint" ]; then
        status="${RED}No endpoint found${NC}"
    elif echo "$endpoint" | grep -q ':'; then
        status="${RED}Invalid endpoint format${NC}"
    else
        # Test ping and capture output
        ping_output=$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" -4 "$endpoint" 2>/dev/null)
        avg_latency=$(echo "$ping_output" | grep "rtt min/avg/max/mdev" | awk '{print $4}' | cut -d'/' -f2)
        
        if [ -n "$avg_latency" ]; then
            status="${GREEN}OK${NC}"
            latency="$avg_latency"
        else
            packet_loss=$(echo "$ping_output" | grep "packet loss" | awk '{print $6}' | sed 's/%//')
            if [ -n "$packet_loss" ] && [ "$packet_loss" -eq 100 ]; then
                status="${RED}Host Unreachable${NC}"
            elif [ -n "$packet_loss" ]; then
                status="${YELLOW}$packet_loss% Loss${NC}"
            else
                status="${RED}Failed${NC}"
            fi
        fi
    fi

    # Print result immediately
    if [ -n "$latency" ]; then
        display_latency="${latency} ms"
    else
        display_latency="-"
    fi
    printf "%-30s %-30s %-15b %s\n" \
        "$filename" \
        "$endpoint" \
        "$status" \
        "$display_latency"

    # Save result to temporary file with sort key
    printf "%s\t%s\t%s\t%s\t%s\n" \
        "$(format_latency "$latency")" \
        "$filename" \
        "$endpoint" \
        "$status" \
        "$latency" >> "$RESULTS_FILE"
done

echo "$SEPARATOR"
echo "Summary (sorted by ping latency):"
echo "$SEPARATOR"
printf "%-30s %-30s %-15s %s\n" "CONFIG FILE" "ENDPOINT" "STATUS" "LATENCY"
echo "$SEPARATOR"

# Sort and display results
sort -n "$RESULTS_FILE" | while IFS=$'\t' read -r _ filename endpoint status latency; do
    if [ -n "$latency" ]; then
        latency="${latency} ms"
    else
        latency="-"
    fi
    printf "%-30s %-30s %-15b %s\n" \
        "$filename" \
        "$endpoint" \
        "$status" \
        "$latency"
done

echo "$SEPARATOR"

# Cleanup will be handled by trap
exit 0
