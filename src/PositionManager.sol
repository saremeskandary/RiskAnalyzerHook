// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces.sol";
import "../lib/RiskMath.sol";
import "../lib/PriceLib.sol";

/**
 * @title LiquidityScoring
 * @notice Evaluates liquidity conditions and scores for risk assessment
 * @dev Implements ILiquidityScoring interface
 */
contract LiquidityScoring is ILiquidityScoring, Ownable, Pausable {
    using Math for uint256;

    // Storage for token information
    mapping(address => TokenInfo) public tokenInfo;
    
    // Storage for historical liquidity data
    mapping(bytes32 => LiquidityHistory) public liquidityHistory;
    
    // Window size for historical data (in number of data points)
    uint256 public constant HISTORY_WINDOW = 24;
    
    // Weights for different components of liquidity score
    uint256 public constant MARKET_CAP_WEIGHT = 30;     // 30%
    uint256 public constant DISTRIBUTION_WEIGHT = 40;    // 40%
    uint256 public constant STABILITY_WEIGHT = 30;       // 30%
    
    // Base points for calculations (100%)
    uint256 public constant BASIS_POINTS = 10000;
    
    // Minimum required token price for calculations
    uint256 public constant MIN_TOKEN_PRICE = 1e6;
    
    // Events
    event LiquidityScoreCalculated(
        bytes32 indexed poolId,
        uint256 score,
        uint256 timestamp
    );
    
    event TokenInfoUpdated(
        address indexed token,
        uint256 marketCap,
        uint256 dailyVolume
    );
    
    // Errors
    error InvalidPrice();
    error InvalidLiquidity();
    error InvalidTicks();
    error TokenNotInitialized();

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Calculate comprehensive liquidity score
     */
    function calculateLiquidityScore(
        uint256 totalLiquidity,
        int256 currentPrice,
        address token0,
        address token1,
        bytes32 poolId,
        int24 tickLower,
        int24 tickUpper
    ) external override whenNotPaused returns (uint256) {
        if (totalLiquidity == 0) revert InvalidLiquidity();
        if (currentPrice <= 0) revert InvalidPrice();
        if (tickLower >= tickUpper) revert InvalidTicks();
        
        // Calculate component scores
        uint256 marketCapScore = calculateMarketCapScore(
            totalLiquidity,
            token0,
            token1
        );
        
        uint256 distributionScore = calculateDistributionScore(
            totalLiquidity,
            currentPrice,
            tickLower,
            tickUpper
        );
        
        uint256 stabilityScore = calculateStabilityScore(
            poolId,
            totalLiquidity
        );
        
        // Calculate weighted average
        uint256 totalScore = (
            (marketCapScore * MARKET_CAP_WEIGHT) +
            (distributionScore * DISTRIBUTION_WEIGHT) +
            (stabilityScore * STABILITY_WEIGHT)
        ) / 100;
        
        // Update history
        updateLiquidityHistory(poolId, totalLiquidity);
        
        emit LiquidityScoreCalculated(poolId, totalScore, block.timestamp);
        
        return totalScore;
    }

    /**
     * @notice Calculate market cap based score
     */
    function calculateMarketCapScore(
        uint256 totalLiquidity,
        address token0,
        address token1
    ) public view override returns (uint256) {
        if (tokenInfo[token0].marketCap == 0 || tokenInfo[token1].marketCap == 0)
            revert TokenNotInitialized();
            
        // Get minimum market cap between tokens
        uint256 minMarketCap = Math.min(
            tokenInfo[token0].marketCap,
            tokenInfo[token1].marketCap
        );
        
        // Calculate liquidity to market cap ratio
        uint256 liquidityRatio = (totalLiquidity * BASIS_POINTS) / minMarketCap;
        
        // Score based on ratio (higher ratio = lower score)
        if (liquidityRatio > BASIS_POINTS) {
            return 0; // Too much liquidity compared to market cap = risky
        }
        
        return BASIS_POINTS - liquidityRatio;
    }

    /**
     * @notice Calculate distribution score based on tick range
     */
    function calculateDistributionScore(
        uint256 totalLiquidity,
        int256 currentPrice,
        int24 tickLower,
        int24 tickUpper
    ) public pure override returns (uint256) {
        uint256 priceUpper = PriceLib.tickToPrice(tickUpper);
        uint256 priceLower = PriceLib.tickToPrice(tickLower);
        uint256 currentPriceUint = uint256(currentPrice);
        
        // Check if current price is within range
        if (currentPriceUint < priceLower || currentPriceUint > priceUpper) {
            return 0;
        }
        
        // Calculate price range ratio
        uint256 rangeRatio = ((priceUpper - priceLower) * BASIS_POINTS) / currentPriceUint;
        
        // Score inversely proportional to range (tighter range = higher score)
        if (rangeRatio > BASIS_POINTS) {
            return BASIS_POINTS - Math.min(rangeRatio - BASIS_POINTS, BASIS_POINTS);
        }
        
        return BASIS_POINTS;
    }

    /**
     * @notice Calculate stability score based on historical data
     */
    function calculateStabilityScore(
        bytes32 poolId,
        uint256 currentLiquidity
    ) public view override returns (uint256) {
        LiquidityHistory storage history = liquidityHistory[poolId];
        
        if (history.liquidityValues.length < 2) {
            return BASIS_POINTS; // Not enough history
        }
        
        uint256 valueCount = history.liquidityValues.length;
        uint256 totalVariation;
        uint256 previousValue = history.liquidityValues[0];
        
        // Calculate average variation
        for (uint256 i = 1; i < valueCount; i++) {
            uint256 currentValue = history.liquidityValues[i];
            uint256 variation;
            
            if (currentValue > previousValue) {
                variation = ((currentValue - previousValue) * BASIS_POINTS) / previousValue;
            } else {
                variation = ((previousValue - currentValue) * BASIS_POINTS) / previousValue;
            }
            
            totalVariation += variation;
            previousValue = currentValue;
        }
        
        uint256 averageVariation = totalVariation / (valueCount - 1);
        
        // Score inversely proportional to variation
        if (averageVariation > BASIS_POINTS) {
            return 0;
        }
        
        return BASIS_POINTS - averageVariation;
    }

    /**
     * @notice Update token information
     */
    function updateTokenInfo(
        address token,
        uint256 marketCap,
        uint256 dailyVolume
    ) external onlyOwner {
        require(token != address(0), "Invalid token");
        require(marketCap > 0, "Invalid market cap");
        
        tokenInfo[token] = TokenInfo({
            marketCap: marketCap,
            dailyVolume: dailyVolume,
            lastUpdate: block.timestamp
        });
        
        emit TokenInfoUpdated(token, marketCap, dailyVolume);
    }

    /**
     * @notice Update liquidity history
     */
    function updateLiquidityHistory(bytes32 poolId, uint256 newLiquidity) internal {
        LiquidityHistory storage history = liquidityHistory[poolId];
        
        if (history.liquidityValues.length == 0) {
            history.liquidityValues = new uint256[](HISTORY_WINDOW);
            history.timestamps = new uint256[](HISTORY_WINDOW);
            history.windowSize = HISTORY_WINDOW;
        }
        
        // Update in circular buffer fashion
        uint256 index = history.currentIndex;
        history.liquidityValues[index] = newLiquidity;
        history.timestamps[index] = block.timestamp;
        
        history.currentIndex = (index + 1) % HISTORY_WINDOW;
    }

    /**
     * @notice Get liquidity history for a pool
     */
    function getLiquidityHistory(bytes32 poolId)
        external
        view
        returns (
            uint256[] memory values,
            uint256[] memory timestamps
        )
    {
        LiquidityHistory storage history = liquidityHistory[poolId];
        return (history.liquidityValues, history.timestamps);
    }

    /**
     * @notice Emergency pause
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Resume operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}