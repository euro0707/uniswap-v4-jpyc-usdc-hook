// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ObservationLibrary} from "./ObservationLibrary.sol";

/// @title BollingerBands
/// @notice Bollinger Bands calculation for dynamic range management
/// @dev Codex version: 2σ, 24-hour timeframe, 1-hour observation intervals
library BollingerBands {
    /// @notice Bollinger Bands configuration
    struct Config {
        uint256 period;              // Number of observations (e.g., 24 for 24 hours)
        uint256 standardDeviation;   // Std dev multiplier (200 = 2.0σ)
        uint256 timeframe;           // Timeframe in seconds (86400 = 24h)
        uint256 softBandBps;         // Soft boundary (180 = 1.8σ)
    }
    
    /// @notice Calculated Bollinger Bands
    struct Bands {
        int24 upper;      // Upper band tick
        int24 middle;     // Middle band (MA) tick
        int24 lower;      // Lower band tick
        uint256 width;    // Band width in bps
        int24 softUpper;  // Soft upper boundary (1.8σ)
        int24 softLower;  // Soft lower boundary (1.8σ)
    }
    
    /// @notice Calculate Bollinger Bands
    /// @param observations Ring buffer of price observations
    /// @param config BB configuration
    /// @return bands Calculated bands
    function calculate(
        ObservationLibrary.RingBuffer storage observations,
        Config memory config
    ) internal view returns (Bands memory bands) {
        // Get recent observations within timeframe
        (ObservationLibrary.Observation[] memory recent, uint256 count) =
            ObservationLibrary.getRecent(observations, config.timeframe);
        
        require(count >= config.period, "Insufficient observations");
        
        // 1. Calculate moving average (MA)
        uint256 sum = 0;
        for (uint256 i = 0; i < count; i++) {
            sum += recent[i].price;
        }
        uint256 ma = sum / count;
        
        // 2. Calculate standard deviation (σ)
        uint256 varianceSum = 0;
        for (uint256 i = 0; i < count; i++) {
            uint256 price = recent[i].price;
            uint256 diff = price > ma ? price - ma : ma - price;
            varianceSum += (diff * diff);
        }
        
        uint256 variance = varianceSum / count;
        uint256 stdDev = sqrt(variance);
        
        // 3. Calculate bands (MA ± 2σ)
        uint256 upperPrice = ma + ((stdDev * config.standardDeviation) / 100);
        uint256 lowerPrice = ma - ((stdDev * config.standardDeviation) / 100);
        
        // 4. Calculate soft boundaries (MA ± 1.8σ)
        uint256 softUpperPrice = ma + ((stdDev * config.softBandBps) / 100);
        uint256 softLowerPrice = ma - ((stdDev * config.softBandBps) / 100);
        
        // Convert to ticks
        bands.middle = priceToTick(ma);
        bands.upper = priceToTick(upperPrice);
        bands.lower = priceToTick(lowerPrice);
        bands.softUpper = priceToTick(softUpperPrice);
        bands.softLower = priceToTick(softLowerPrice);
        
        // Calculate band width in basis points
        bands.width = ((upperPrice - lowerPrice) * 10000) / ma;
        
        return bands;
    }
    
    /// @notice Check if price is out of bands
    /// @param currentTick Current price tick
    /// @param bands Calculated bands
    /// @return isOutside True if outside 2σ bands
    /// @return isAbove True if above upper band
    function isOutOfBands(
        int24 currentTick,
        Bands memory bands
    ) internal pure returns (bool isOutside, bool isAbove) {
        isAbove = currentTick > bands.upper;
        bool isBelow = currentTick < bands.lower;
        isOutside = isAbove || isBelow;
    }
    
    /// @notice Check if price is in soft boundary zone
    /// @param currentTick Current price tick
    /// @param bands Calculated bands
    /// @return isInSoftZone True if between 1.8σ and 2.0σ
    function isInSoftZone(
        int24 currentTick,
        Bands memory bands
    ) internal pure returns (bool isInSoftZone) {
        bool aboveSoftUpper = currentTick > bands.softUpper && currentTick <= bands.upper;
        bool belowSoftLower = currentTick < bands.softLower && currentTick >= bands.lower;
        isInSoftZone = aboveSoftUpper || belowSoftLower;
    }
    
    /// @notice Square root using Babylonian method
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
    
    /// @notice Convert price to tick (simplified)
    function priceToTick(uint256 price) internal pure returns (int24) {
        // Simplified conversion for JPYC/USDC range
        // Actual implementation should use TickMath library
        return int24(int256(price >> 16));
    }
}
