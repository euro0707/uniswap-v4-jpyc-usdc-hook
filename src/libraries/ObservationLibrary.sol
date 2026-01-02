// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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
    
    /// @notice Validate that recent observations span multiple blocks
    /// @dev Prevents single-block price manipulation attacks
    /// @param self Ring buffer of observations
    /// @param minBlocks Minimum number of unique blocks required
    /// @return isValid True if observations span enough blocks
    function validateMultiBlock(
        RingBuffer storage self,
        uint256 minBlocks
    ) internal view returns (bool isValid) {
        if (self.count < minBlocks) {
            return false;
        }

        uint256 uniqueBlocks = 0;
        uint256 lastBlock = 0;

        // Check recent observations (up to minBlocks * 2 for safety margin)
        uint256 checkCount = self.count < minBlocks * 2 ? self.count : minBlocks * 2;
        uint256 currentIdx = self.index == 0 ? 99 : self.index - 1;

        for (uint256 i = 0; i < checkCount; i++) {
            uint256 blockNum = self.data[currentIdx].blockNumber;
            if (blockNum != lastBlock && blockNum > 0) {
                uniqueBlocks++;
                lastBlock = blockNum;
            }
            if (uniqueBlocks >= minBlocks) {
                return true;
            }
            currentIdx = currentIdx == 0 ? 99 : currentIdx - 1;
        }

        return false;
    }

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
            uint256 change;
            if (currSqrt > prevSqrt) {
                uint256 numerator = (currSqrt + prevSqrt) * (currSqrt - prevSqrt);
                uint256 denominator = prevSqrt * prevSqrt;
                change = (numerator * 10000) / denominator;
            } else {
                uint256 numerator = (currSqrt + prevSqrt) * (prevSqrt - currSqrt);
                uint256 denominator = prevSqrt * prevSqrt;
                change = (numerator * 10000) / denominator;
            }

            if (change > maxChange) {
                maxChange = change;
            }

            currentIdx = prevIdx;
        }

        return maxChange;
    }
}
