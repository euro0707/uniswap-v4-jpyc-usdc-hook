// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title ObservationLibrary
/// @notice Price observation data structure for time-series analysis
library ObservationLibrary {
    /// @notice Single price observation
    struct Observation {
        uint256 timestamp;
        uint256 blockNumber;
        uint160 sqrtPriceX96;
    }
    
    /// @notice Ring buffer for observations
    struct RingBuffer {
        Observation[100] data;
        uint256 index;
        uint256 count;
    }
    
    /// @notice Add new observation to ring buffer
    function push(
        RingBuffer storage self,
        uint256 timestamp,
        uint160 sqrtPriceX96
    ) internal {
        self.data[self.index] = Observation({
            timestamp: timestamp,
            blockNumber: block.number,
            sqrtPriceX96: sqrtPriceX96
        });

        self.index = (self.index + 1) % 100;
        if (self.count < 100) {
            self.count++;
        }
    }
    
    /// @notice Get observations within timeframe
    function getRecent(
        RingBuffer storage self,
        uint256 timeframe
    ) internal view returns (Observation[] memory observations, uint256 count) {
        // Handle underflow: if block.timestamp < timeframe, use all observations
        uint256 oldestTimestamp = block.timestamp > timeframe ? block.timestamp - timeframe : 0;
        observations = new Observation[](self.count);
        count = 0;

        for (uint256 i = 0; i < self.count; i++) {
            Observation storage obs = self.data[i];
            if (obs.timestamp >= oldestTimestamp) {
                observations[count] = obs;
                count++;
            }
        }
    }
    
    /// @notice Check if all observations are stale (older than threshold)
    /// @dev Used to detect long periods of inactivity and trigger ring reset
    /// @param self Ring buffer of observations
    /// @param stalenessThreshold Time threshold in seconds (e.g., 30 minutes)
    /// @return isStale True if all observations are older than threshold
    function isStale(
        RingBuffer storage self,
        uint256 stalenessThreshold
    ) internal view returns (bool) {
        if (self.count == 0) {
            return true; // Empty ring is considered stale
        }

        uint256 oldestAllowedTimestamp = block.timestamp > stalenessThreshold
            ? block.timestamp - stalenessThreshold
            : 0;

        // Check if all observations are older than threshold
        for (uint256 i = 0; i < self.count; i++) {
            if (self.data[i].timestamp >= oldestAllowedTimestamp) {
                return false; // Found at least one fresh observation
            }
        }

        return true; // All observations are stale
    }

    /// @notice Reset ring buffer to accept new observations after staleness
    /// @dev Clears all existing observations and resets counters
    /// @param self Ring buffer of observations
    function reset(RingBuffer storage self) internal {
        self.index = 0;
        self.count = 0;
        // Note: No need to clear data array, as it will be overwritten
    }

    /// @notice Validate that recent observations span multiple blocks
    /// @dev Prevents single-block price manipulation attacks
    /// @param self Ring buffer of observations
    /// @param minBlocks Minimum number of unique blocks required
    /// @return isValid True if observations span enough blocks
    // slither-disable-start cyclomatic-complexity
    function validateMultiBlock(
        RingBuffer storage self,
        uint256 minBlocks
    ) internal view returns (bool isValid) {
        if (self.count < minBlocks) {
            return false;
        }

        // Time range check: observations must span at least 30 minutes for mature pools
        // For newer pools with fewer observations, use MIN_UPDATE_INTERVAL * minBlocks
        uint256 MIN_TIME_SPAN = self.count < 10 ? 10 minutes * minBlocks : 30 minutes;
        uint256 oldestAllowedTimestamp = block.timestamp > MIN_TIME_SPAN ? block.timestamp - MIN_TIME_SPAN : 0;

        uint256 uniqueBlocks = 0;
        uint256 checkCount = self.count < minBlocks * 2 ? self.count : minBlocks * 2;
        uint256 currentIdx = self.index == 0 ? 99 : self.index - 1;

        // Track unique blocks using a simple linear scan with comparison
        // Note: We can't use mapping in memory, so we track last seen blocks
        uint256 maxSeen = checkCount < 20 ? checkCount : 20;
        uint256[] memory seenBlocks = new uint256[](maxSeen);
        uint256 seenCount = 0;

        for (uint256 i = 0; i < checkCount; i++) {
            uint256 blockNum = self.data[currentIdx].blockNumber;
            uint256 timestamp = self.data[currentIdx].timestamp;

            // Skip observations that are too old
            if (timestamp < oldestAllowedTimestamp) {
                currentIdx = currentIdx == 0 ? 99 : currentIdx - 1;
                continue;
            }

            // Check if this block number is new
            if (blockNum > 0) {
                bool isNewBlock = true;
                for (uint256 j = 0; j < seenCount; j++) {
                    if (seenBlocks[j] == blockNum) {
                        isNewBlock = false;
                        break;
                    }
                }

                if (isNewBlock && seenCount < maxSeen) {
                    seenBlocks[seenCount] = blockNum;
                    seenCount++;
                    uniqueBlocks++;
                }
            }

            if (uniqueBlocks >= minBlocks) {
                return true;
            }

            currentIdx = currentIdx == 0 ? 99 : currentIdx - 1;
        }

        return uniqueBlocks >= minBlocks;
    }
    // slither-disable-end cyclomatic-complexity

    /// @notice Calculate maximum price change in recent observations
    /// @param self Ring buffer of observations
    /// @param lookback Number of recent observations to check
    /// @return maxChange Maximum percentage change in basis points
    function getMaxPriceChange(
        RingBuffer storage self,
        uint256 lookback
    ) internal view returns (uint256 maxChange) {
        if (self.count < 2) {
            return 0;
        }

        uint256 checkCount = self.count < lookback ? self.count : lookback;
        uint256 currentIdx = self.index == 0 ? 99 : self.index - 1;

        maxChange = 0;

        for (uint256 i = 1; i < checkCount; i++) {
            uint256 currIdx = currentIdx;
            uint256 prevIdx = currentIdx == 0 ? 99 : currentIdx - 1;

            uint256 currSqrt = uint256(self.data[currIdx].sqrtPriceX96);
            uint256 prevSqrt = uint256(self.data[prevIdx].sqrtPriceX96);

            if (prevSqrt == 0) {
                currentIdx = prevIdx;
                continue;
            }

            // 実際の価格変動率を計算: price = sqrtPrice^2
            // 変動率 = |currPrice - prevPrice| / prevPrice
            //       = |currSqrt^2 - prevSqrt^2| / prevSqrt^2
            //       = |(currSqrt + prevSqrt)(currSqrt - prevSqrt)| / prevSqrt^2
            // 段階的に除算: = ((currSqrt + prevSqrt) * diff / prevSqrt) * 10000 / prevSqrt
            // 両方の除算で切り上げ (mulDivRoundingUp) で保守的に評価
            uint256 change;
            if (currSqrt > prevSqrt) {
                uint256 diff = currSqrt - prevSqrt;
                // (currSqrt + prevSqrt) * diff / prevSqrt (切り上げ)
                uint256 temp = FullMath.mulDivRoundingUp(currSqrt + prevSqrt, diff, prevSqrt);
                // temp * 10000 / prevSqrt (通常除算で過大評価を防ぐ)
                change = FullMath.mulDiv(temp, 10000, prevSqrt);
            } else {
                uint256 diff = prevSqrt - currSqrt;
                // (currSqrt + prevSqrt) * diff / prevSqrt (切り上げ)
                uint256 temp = FullMath.mulDivRoundingUp(currSqrt + prevSqrt, diff, prevSqrt);
                // temp * 10000 / prevSqrt (通常除算で過大評価を防ぐ)
                change = FullMath.mulDiv(temp, 10000, prevSqrt);
            }

            if (change > maxChange) {
                maxChange = change;
            }

            currentIdx = prevIdx;
        }

        return maxChange;
    }
}
