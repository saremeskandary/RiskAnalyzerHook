1. Base Libraries (No interfaces, just utilities):
   - `RiskMath.sol` - Shared mathematical utilities
   - `PriceLib.sol` - Price calculation utilities

2. Core Implementation Contracts:
   - Interface: `IVolatilityOracle` → Implementation: `VolatilityOracle.sol`
   - Interface: `ILiquidityScoring` → Implementation: `LiquidityScoring.sol`
   - Interface: `IRiskRegistry` → Implementation: `RiskRegistry.sol`

3. Risk Management Contracts:
   - Interface: `IPositionManager` → Implementation: `PositionManager.sol`
   - Interface: `IRiskNotifier` → Implementation: `RiskNotifier.sol`
   - Interface: `IRiskController` → Implementation: `RiskController.sol`

4. Aggregation Contract:
   - Interface: `IRiskAggregator` → Implementation: `RiskAggregator.sol`

5. Main Hook Contract:
   - Interface: `IUniswapV4RiskAnalyzerHook` → Implementation: `RiskAnalyzerHook.sol`

Each interface has a direct implementation with a matching name (minus the 'I' prefix). The only additional files are the utility libraries that don't have interfaces.

Implementation order should be:
1. Libraries (RiskMath, PriceLib)
2. VolatilityOracle
3. LiquidityScoring
4. RiskRegistry
5. PositionManager
6. RiskNotifier
7. RiskController
8. RiskAggregator
9. RiskAnalyzerHook