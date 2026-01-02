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

        // 1. Calculate moving average (MA) using ticks
        int256 sumTick = 0;
        for (uint256 i = 0; i < count; i++) {
            sumTick += int256(recent[i].tick);
        }
        int256 maTick = sumTick / int256(count);

        // 2. Calculate standard deviation (σ) in tick space
        uint256 varianceSum = 0;
        for (uint256 i = 0; i < count; i++) {
            int256 tick = int256(recent[i].tick);
            int256 diff = tick > maTick ? tick - maTick : maTick - tick;
            varianceSum += uint256(diff * diff);
        }

        uint256 variance = varianceSum / count;
        uint256 stdDev = sqrt(variance);

        // 3. Calculate bands (MA ± 2σ) in tick space
        int256 deviation = int256((stdDev * config.standardDeviation) / 100);
        int256 upperTick = maTick + deviation;
        int256 lowerTick = maTick - deviation;

        // 4. Calculate soft boundaries (MA ± 1.8σ) in tick space
        int256 softDeviation = int256((stdDev * config.softBandBps) / 100);
        int256 softUpperTick = maTick + softDeviation;
        int256 softLowerTick = maTick - softDeviation;

        // Assign ticks (with range checks)
        bands.middle = _toInt24(maTick);
        bands.upper = _toInt24(upperTick);
        bands.lower = _toInt24(lowerTick);
        bands.softUpper = _toInt24(softUpperTick);
        bands.softLower = _toInt24(softLowerTick);

        // Calculate band width in basis points (using tick range)
        int256 tickDiff = upperTick - lowerTick;
        uint256 tickRange = tickDiff >= 0 ? uint256(tickDiff) : uint256(-tickDiff);
        // Use tick range directly as width (represents volatility in tick space)
        // For JPYC/USDC, typical tick spacing is small, so raw range is meaningful
        bands.width = tickRange;

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
    /// @return inSoftZone True if between 1.8σ and 2.0σ
    function isInSoftZone(
        int24 currentTick,
        Bands memory bands
    ) internal pure returns (bool inSoftZone) {
        bool aboveSoftUpper = currentTick > bands.softUpper && currentTick <= bands.upper;
        bool belowSoftLower = currentTick < bands.softLower && currentTick >= bands.lower;
        inSoftZone = aboveSoftUpper || belowSoftLower;
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

    /// @notice Safely convert int256 to int24 with bounds checking
    function _toInt24(int256 value) private pure returns (int24) {
        // int24 range: -8388608 to 8388607
        if (value > 8388607) return 8388607;
        if (value < -8388608) return -8388608;
        return int24(value);
    }
}
