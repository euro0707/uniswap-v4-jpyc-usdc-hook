// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ObservationLibrary
/// @notice Price observation data structure for time-series analysis
library ObservationLibrary {
    /// @notice Single price observation
    struct Observation {
        uint256 timestamp;
        uint160 sqrtPriceX96;
        uint256 price;
        int24 tick;
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
        uint256 price = _sqrtPriceX96ToPrice(sqrtPriceX96);
        int24 tick = _sqrtPriceX96ToTick(sqrtPriceX96);
        
        self.data[self.index] = Observation({
            timestamp: timestamp,
            sqrtPriceX96: sqrtPriceX96,
            price: price,
            tick: tick
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
        uint256 oldestTimestamp = block.timestamp - timeframe;
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
    
    function _sqrtPriceX96ToPrice(uint160 sqrtPriceX96) private pure returns (uint256) {
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return price >> 192;
    }
    
    function _sqrtPriceX96ToTick(uint160 sqrtPriceX96) private pure returns (int24) {
        return int24(int256((uint256(sqrtPriceX96) >> 32)));
    }
}
