// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHyperionTypes} from "./IHyperionTypes.sol";

/**
 * @title IHyperionClearingHouse
 * @notice Central protocol orchestrator managing positions, orders, and funding settlement.
 * @dev Coordinates vAMM execution, margin checks, fee routing, and position updates.
 */
interface IHyperionClearingHouse is IHyperionTypes {
    event PositionOpened(
        address indexed account,
        uint256 indexed marketId,
        Side side,
        uint256 sizeDelta,
        uint256 openNotionalDelta,
        uint256 executionPrice,
        uint256 feePaid
    );

    event PositionModified(
        address indexed account,
        uint256 indexed marketId,
        Side side,
        uint256 newSize,
        uint256 newOpenNotional,
        int256 realizedPnL,
        uint256 executionPrice
    );

    event PositionClosed(
        address indexed account,
        uint256 indexed marketId,
        Side side,
        uint256 closedSize,
        int256 netRealizedPnL,
        uint256 closePrice
    );

    event FundingSettled(
        address indexed account, uint256 indexed marketId, int256 fundingPayment, int256 cumulativeFundingRate
    );

    event MarketRegistered(uint256 indexed marketId, string symbol, address vamm);
    event MarketParametersUpdated(uint256 indexed marketId, uint256 maxLeverage, uint256 imr, uint256 mmr);

    /**
     * @notice Opens or increases a perpetual futures position on a given market.
     * @param marketId Identifier of the targeted perpetual market
     * @param side Position direction (LONG or SHORT)
     * @param baseAmount Quantity of base contracts to purchase/sell (Wad)
     * @param maxSlippagePrice Worst-case execution price acceptable (Wad)
     * @param mode Cross or Isolated margin
     * @return positionId Resulting position identifier
     * @return executionPrice Actual execution price attained on vAMM (Wad)
     */
    function openPosition(uint256 marketId, Side side, uint256 baseAmount, uint256 maxSlippagePrice, MarginMode mode)
        external
        returns (uint256 positionId, uint256 executionPrice);

    /**
     * @notice Decreases or fully exits an existing perpetual position.
     * @param marketId Market identifier
     * @param baseAmount Quantity of base asset to close (Wad)
     * @param minSlippagePrice Worst-case acceptable execution price (Wad)
     * @return realizedPnL Net PnL realized upon closing (Wad)
     * @return executionPrice Actual price attained on vAMM (Wad)
     */
    function closePosition(uint256 marketId, uint256 baseAmount, uint256 minSlippagePrice)
        external
        returns (int256 realizedPnL, uint256 executionPrice);

    /**
     * @notice Reduces an account's position during liquidation or insurance takeover.
     * @dev Only callable by authorized Liquidator.
     * @param account Trader account address
     * @param marketId Market identifier
     * @param closedSize Amount of base position to close (Wad)
     * @return remainingSize Position size remaining after reduction (Wad)
     */
    function reducePositionForLiquidation(address account, uint256 marketId, uint256 closedSize)
        external
        returns (uint256 remainingSize);

    /**
     * @notice Settles accrued funding debt or credit for a specific account position.
     * @param account Trader account address
     * @param marketId Market identifier
     * @return fundingPayment Net funding transferred (positive: payment owed, negative: payment received)
     */
    function settleFunding(address account, uint256 marketId) external returns (int256 fundingPayment);

    /**
     * @notice Retrieves position state for an account in a market.
     */
    function getPosition(address account, uint256 marketId) external view returns (Position memory);

    /**
     * @notice Calculates the unrealized profit or loss (uPnL) for a trader's position using current mark price.
     * @param account Trader account address
     * @param marketId Market identifier
     * @return upnl Signed unrealized profit/loss in Wad
     */
    function getUnrealizedPnL(address account, uint256 marketId) external view returns (int256 upnl);

    /**
     * @notice Returns market configuration for a registered market.
     */
    function getMarketConfig(uint256 marketId) external view returns (MarketConfig memory);

    /**
     * @notice Returns total open interest in base units for both sides.
     */
    function getOpenInterest(uint256 marketId) external view returns (uint256 longOI, uint256 shortOI);

    /**
     * @notice Returns the highest registered market identifier count.
     */
    function marketCount() external view returns (uint256);
}
