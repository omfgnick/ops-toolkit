#!/bin/bash

# Set the host to scan
HOST="example.com"

# Set the maximum number of ports to scan
MAX_PORTS=65535

# Create an array to store the open ports
open_ports=()

# Scan the ports using nmap
for ((i=1; i<=$MAX_PORTS; i++)); do
  if nmap -p $i $HOST | grep -q "open"; then
    open_ports+=($i)
  fi
done

# Rate the vulnerability of each open port
for port in "${open_ports[@]}"; do
  case $port in
    21) echo "FTP ($port) - Vulnerability rating: 8/10";;
    22) echo "SSH ($port) - Vulnerability rating: 6/10";;
    80) echo "HTTP ($port) - Vulnerability rating: 5/10";;
    443) echo "HTTPS ($port) - Vulnerability rating: 4/10";;
    *) echo "Unknown port ($port) - Vulnerability rating: 10/10";;
  esac
done
