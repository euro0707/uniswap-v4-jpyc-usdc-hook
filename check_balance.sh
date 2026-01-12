#!/bin/bash
set -euo pipefail

# Configuration
ADDRESS="0xb398F9a5a8BD50e23e20281194d0D614c19b5789"
RPC_URL="https://ethereum-sepolia-rpc.publicnode.com"

echo "Checking Sepolia ETH balance..."
echo "Address: $ADDRESS"
echo ""

# Fetch balance with error handling
if ! BALANCE=$(cast balance "$ADDRESS" --rpc-url "$RPC_URL" 2>&1); then
    echo "Error: Failed to fetch balance from RPC" >&2
    echo "Details: $BALANCE" >&2
    exit 1
fi

# Validate that BALANCE is numeric
if ! [[ "$BALANCE" =~ ^[0-9]+$ ]]; then
    echo "Error: Invalid balance format (expected numeric Wei value)" >&2
    echo "Received: $BALANCE" >&2
    exit 1
fi

echo "Balance (Wei): $BALANCE"

# Convert to ETH with error handling
if ! BALANCE_ETH=$(cast --to-unit "$BALANCE" ether 2>&1); then
    echo "Error: Failed to convert balance to ETH" >&2
    echo "Details: $BALANCE_ETH" >&2
    exit 1
fi

echo "Balance (ETH): $BALANCE_ETH"
