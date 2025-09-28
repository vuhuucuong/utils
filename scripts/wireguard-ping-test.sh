#!/usr/bin/env bash

set -euo pipefail

# WireGuard endpoint ping tester
# - Scans a directory for *.conf files
# - Extracts Endpoint hosts
# - Pings all unique endpoints in parallel (default 20 concurrent)
# - Prints results sorted by lowest average latency

usage() {
	cat <<EOF
Usage: $(basename "$0") [-d DIR] [-c COUNT] [-P CONCURRENCY] [-t TIMEOUT]

Options:
	-d DIR         Directory containing WireGuard .conf files (default: current dir)
	-c COUNT       Ping count per endpoint (default: 3)
	-P CONCURRENCY Number of concurrent pings (default: 20)
	-t TIMEOUT     Timeout per ping command in seconds (default: 5)
	-h             Show this help

Notes:
	- IPv6 endpoints in configs like [2001:db8::1]:51820 are supported.
	- Duplicate endpoints across configs are de-duplicated before pinging.
EOF
}

DIR="$(pwd)"
COUNT=3
CONCURRENCY=20
PING_TIMEOUT=5

while getopts ":d:c:P:t:h" opt; do
	case "$opt" in
		d) DIR="$OPTARG" ;;
		c) COUNT="$OPTARG" ;;
		P) CONCURRENCY="$OPTARG" ;;
		t) PING_TIMEOUT="$OPTARG" ;;
		h) usage; exit 0 ;;
		:) echo "Option -$OPTARG requires an argument" >&2; usage; exit 1 ;;
		\?) echo "Unknown option: -$OPTARG" >&2; usage; exit 1 ;;
	esac
done

if ! command -v ping >/dev/null 2>&1; then
	echo "Error: 'ping' command not found. Please install iputils-ping." >&2
	exit 1
fi

if [[ ! -d "$DIR" ]]; then
	echo "Error: Directory not found: $DIR" >&2
	exit 1
fi

trim() { # usage: trim "  text  " -> "text"
	local s="$*"
	s="${s#${s%%[![:space:]]*}}"  # leading
	s="${s%${s##*[![:space:]]}}"  # trailing
	printf '%s' "$s"
}

# Parse host from a WireGuard Endpoint value (hostname:port, IP:port, [IPv6]:port)
parse_endpoint_host() {
	local ep="$1"
	ep="$(trim "${ep%%#*}")"  # strip trailing comment and trim
	if [[ -z "$ep" ]]; then
		return 1
	fi
	if [[ "$ep" =~ ^\[[^]]+\]:[0-9]+$ ]]; then
		# [IPv6]:port -> extract content inside [] before :
		local host
		host="${ep%%]:*}"
		host="${host#\[}"
		printf '%s' "$host"
		return 0
	fi
	# Generic hostname:port (IPv4 or DNS name). For safety, strip last colon+port
	local host="$ep"
	host="${host%:*}"
	printf '%s' "$host"
}

# Determine if a host string looks like IPv6 (contains ':')
is_ipv6() {
	[[ "$1" == *:* ]]
}

# Ping a host and print: "<avg_ms>\t<host>\t<source_file>\n"
ping_host() {
	local host="$1" src="$2" count="$3" timeout_s="$4"

	# Prefer -6 only when clearly IPv6; else let ping decide
	local ping_cmd=(ping -n -c "$count" -W 1 "$host")
	if is_ipv6 "$host"; then
		ping_cmd=(ping -6 -n -c "$count" -W 1 "$host")
	fi

	local out rc
	if ! out=$(timeout "$timeout_s" "${ping_cmd[@]}" 2>/dev/null); then
		# Unreachable or timeout; set a large sentinel value for sorting
		printf '%s\t%s\t%s\n' "999999.000" "$host" "$src"
		return 0
	fi

	# Extract average latency from the summary line (Linux iputils: rtt min/avg/max/mdev = a/b/c/d ms)
	local avg
	avg=$(printf '%s\n' "$out" | awk -F'/' '/rtt .* =/ {print $5}')
	if [[ -z "$avg" ]]; then
		# Fallback: parse from "avg =" forms (robustness)
		avg=$(printf '%s\n' "$out" | sed -n 's/.*= *[^/]*\/\([^/]*\)\/.*/\1/p' | head -n1)
	fi
	if [[ -z "$avg" ]]; then
		# Could not parse; treat as unreachable
		printf '%s\t%s\t%s\n' "999999.000" "$host" "$src"
		return 0
	fi

	printf '%s\t%s\t%s\n' "$avg" "$host" "$src"
}

tmp_endpoints=$(mktemp)
tmp_results=$(mktemp)
trap 'rm -f "$tmp_endpoints" "$tmp_results"' EXIT

# Collect endpoints from .conf files
while IFS= read -r -d '' file; do
	# Read file line-by-line; look for Endpoint = ... (case-insensitive)
	while IFS= read -r line; do
		# Skip comments-only lines
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		# Match Endpoint
		if [[ "$line" =~ ^[[:space:]]*[Ee][Nn][Dd][Pp][Oo][Ii][Nn][Tt][[:space:]]*= ]]; then
			val="${line#*=}"
			val="$(trim "${val%%#*}")"
			[[ -z "$val" ]] && continue
			host=$(parse_endpoint_host "$val" || true)
			[[ -z "$host" ]] && continue
			printf '%s\t%s\n' "$host" "$file" >> "$tmp_endpoints"
		fi
	done < "$file"
done < <(find "$DIR" -type f -name '*.conf' -print0)

if [[ ! -s "$tmp_endpoints" ]]; then
	echo "No endpoints found in $DIR (no 'Endpoint =' lines in *.conf)." >&2
	exit 2
fi

# Deduplicate by host (keep first source file)
mapfile -t uniq_lines < <(awk -F '\t' '!seen[$1]++' "$tmp_endpoints")

# Run pings with bounded concurrency, collect results (portable, no wait -n)
for ln in "${uniq_lines[@]}"; do
	# Throttle to CONCURRENCY background jobs
	while (( $(jobs -rp | wc -l) >= CONCURRENCY )); do
		sleep 0.05
	done
	host="${ln%%$'\t'*}"
	src="${ln#*$'\t'}"
	(
		ping_host "$host" "$src" "$COUNT" "$PING_TIMEOUT" >> "$tmp_results"
	) &
done
wait

# Print sorted results
if [[ -s "$tmp_results" ]]; then
	printf '\nResults (sorted by average latency)\n'
	printf '-----------------------------------\n'
	# Format: show "unreachable" for sentinel
	sort -t $'\t' -k1,1n "$tmp_results" | awk -F '\t' '
		function fmt(ms) {
			if (ms+0 >= 999999) return "unreachable";
			return sprintf("%.3f ms", ms+0);
		}
		{ printf "%-12s  %-40s  %s\n", fmt($1), $2, $3 }
	'
else
	echo "No results recorded (unexpected)." >&2
	exit 3
fi

