#!/bin/bash
echo "Checking Sepolia ETH balance..."
echo "Address: 0xb398F9a5a8BD50e23e20281194d0D614c19b5789"
echo ""
BALANCE=$(cast balance 0xb398F9a5a8BD50e23e20281194d0D614c19b5789 --rpc-url https://ethereum-sepolia-rpc.publicnode.com)
echo "Balance (Wei): $BALANCE"
echo "Balance (ETH): $(cast --to-unit $BALANCE ether 2>/dev/null || echo '0')"
