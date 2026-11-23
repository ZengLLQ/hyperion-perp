// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHyperionClearingHouse} from "../interfaces/IHyperionClearingHouse.sol";
import {IHyperionVAMM} from "../interfaces/IHyperionVAMM.sol";
import {IHyperionMargin} from "../interfaces/IHyperionMargin.sol";
import {IHyperionFundingController} from "../interfaces/IHyperionFundingController.sol";
import {IHyperionOracleRelay} from "../interfaces/IHyperionOracleRelay.sol";
import {WadRayMath} from "../libraries/WadRayMath.sol";
import {SignedMath} from "../libraries/SignedMath.sol";
import {TransientStorage} from "../libraries/TransientStorage.sol";

/**
 * @title HyperionClearingHouse
 * @notice Central trade execution and perpetual lifecycle clearinghouse.
 * @dev Manages position entries/exits, open interest tracking, funding fee accrual, and fee distribution.
 */
contract HyperionClearingHouse is IHyperionClearingHouse {
    using WadRayMath for uint256;
    using SignedMath for int256;

    // =========================================================================
    // IMMUTABLES & CONSTANTS
    // =========================================================================

    address public immutable owner;
    address public marginEngine;
    address public fundingController;
    address public oracleRelay;
    address public feeTreasury;
    address public liquidator;

    uint256 internal constant WAD = 1e18;
    int256 internal constant RAY = 1e27;

    // =========================================================================
    // STATE VARIABLES
    // =========================================================================

    // Market registry: Market ID => MarketConfig
    mapping(uint256 => MarketConfig) public marketConfigs;
    uint256 public override marketCount;

    // Open Interest: Market ID => Long OI / Short OI (Wad)
    mapping(uint256 => uint256) public longOpenInterest;
    mapping(uint256 => uint256) public shortOpenInterest;

    // Trader Positions: Account => Market ID => Position
    mapping(address => mapping(uint256 => Position)) public positions;

    // Next position sequence counter
    uint256 public nextPositionId = 1;

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert UnauthorizedCaller();
        _;
    }

    modifier nonReentrant() {
        TransientStorage.lock();
        _;
        TransientStorage.unlock();
    }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    constructor(address _owner) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
    }

    // =========================================================================
    // ADMIN CONFIGURATION
    // =========================================================================

    /**
     * @notice Sets dependent system contracts.
     */
    function setSystemAddresses(
        address _marginEngine,
        address _fundingController,
        address _oracleRelay,
        address _feeTreasury
    ) external onlyOwner {
        if (
            _marginEngine == address(0) || _fundingController == address(0) || _oracleRelay == address(0)
                || _feeTreasury == address(0)
        ) revert ZeroAddress();

        marginEngine = _marginEngine;
        fundingController = _fundingController;
        oracleRelay = _oracleRelay;
        feeTreasury = _feeTreasury;
    }

    /**
     * @notice Sets liquidator contract.
     */
    function setLiquidator(address _liquidator) external onlyOwner {
        if (_liquidator == address(0)) revert ZeroAddress();
        liquidator = _liquidator;
    }

    /**
     * @notice Registers a new perpetual futures market.
     */
    function registerMarket(
        uint256 marketId,
        string calldata symbol,
        address vamm,
        uint256 maxLeverage,
        uint256 imr,
        uint256 mmr,
        uint256 liquidationPenalty,
        uint256 takerFeeRate,
        uint256 makerFeeRate,
        uint256 maxOpenInterest
    ) external onlyOwner {
        if (vamm == address(0)) revert ZeroAddress();
        if (marketConfigs[marketId].vamm != address(0)) revert MarketAlreadyExists();
        if (imr <= mmr || maxLeverage == 0) revert InvalidMarket();

        marketConfigs[marketId] = MarketConfig({
            marketId: marketId,
            symbol: symbol,
            vamm: vamm,
            maxLeverage: maxLeverage,
            initialMarginRatio: imr,
            maintenanceMarginRatio: mmr,
            liquidationPenalty: liquidationPenalty,
            takerFeeRate: takerFeeRate,
            makerFeeRate: makerFeeRate,
            maxOpenInterest: maxOpenInterest,
            liquidationFeeSplit: 0.6e18, // 60% of liquidation fee to insurance fund
            isActive: true
        });

        if (marketId > marketCount) {
            marketCount = marketId;
        }

        emit MarketRegistered(marketId, symbol, vamm);
    }

    // =========================================================================
    // POSITION MANAGEMENT
    // =========================================================================

    /// @inheritdoc IHyperionClearingHouse
    function openPosition(uint256 marketId, Side side, uint256 baseAmount, uint256 maxSlippagePrice, MarginMode mode)
        external
        override
        nonReentrant
        returns (uint256 positionId, uint256 executionPrice)
    {
        MarketConfig memory cfg = marketConfigs[marketId];
        if (!cfg.isActive) revert MarketNotActive();
        if (baseAmount == 0) revert ZeroAmount();

        // Check Circuit Breaker
        if (IHyperionOracleRelay(oracleRelay).isCircuitBreakerTripped(marketId)) {
            revert OracleDeviationExceeded();
        }

        // Settle prior funding before modifying position
        _settleFunding(msg.sender, marketId);

        // Execute swap on vAMM
        uint256 quoteTransferred;
        (quoteTransferred, executionPrice) = IHyperionVAMM(cfg.vamm).executeSwap(side, baseAmount);

        // Check slippage limits
        if (side == Side.LONG && executionPrice > maxSlippagePrice) revert SlippageExceeded();
        if (side == Side.SHORT && executionPrice < maxSlippagePrice) revert SlippageExceeded();

        // Enforce Open Interest caps
        if (side == Side.LONG) {
            if (longOpenInterest[marketId] + baseAmount > cfg.maxOpenInterest) revert ExceedsMaxOpenInterest();
            longOpenInterest[marketId] += baseAmount;
        } else {
            if (shortOpenInterest[marketId] + baseAmount > cfg.maxOpenInterest) revert ExceedsMaxOpenInterest();
            shortOpenInterest[marketId] += baseAmount;
        }

        // Deduct taker fee
        uint256 takerFee = quoteTransferred.wadMul(cfg.takerFeeRate);
        if (takerFee > 0) {
            IHyperionMargin(marginEngine).settleRealizedPnL(msg.sender, -int256(takerFee));
        }

        // Update position records
        Position storage pos = positions[msg.sender][marketId];
        if (pos.size == 0) {
            pos.marketId = marketId;
            pos.account = msg.sender;
            pos.side = side;
            pos.size = baseAmount;
            pos.openNotional = quoteTransferred;
            pos.entryPrice = executionPrice;
            pos.lastCumulativeFunding = IHyperionFundingController(fundingController).getCumulativeFundingRate(marketId);
            pos.lastUpdatedTimestamp = block.timestamp;
            pos.marginMode = mode;
        } else {
            if (pos.side == side) {
                // Increasing position
                pos.size += baseAmount;
                pos.openNotional += quoteTransferred;
                pos.entryPrice = pos.openNotional.wadDiv(pos.size);
                pos.lastUpdatedTimestamp = block.timestamp;
            } else {
                // Reversing or crossing positions - closePosition should be used first
                revert InvalidMarket();
            }
        }

        // Verify margin requirements after opening position
        int256 equity = IHyperionMargin(marginEngine).getAccountEquity(msg.sender);
        uint256 totalIMR = IHyperionMargin(marginEngine).getTotalInitialMargin(msg.sender);
        if (equity <= 0 || uint256(equity) < totalIMR) revert InsufficientFreeMargin();

        positionId = nextPositionId++;
        emit PositionOpened(msg.sender, marketId, side, baseAmount, quoteTransferred, executionPrice, takerFee);
    }

    /// @inheritdoc IHyperionClearingHouse
    function closePosition(uint256 marketId, uint256 baseAmount, uint256 minSlippagePrice)
        external
        override
        nonReentrant
        returns (int256 realizedPnL, uint256 executionPrice)
    {
        MarketConfig memory cfg = marketConfigs[marketId];
        if (!cfg.isActive) revert MarketNotActive();

        Position storage pos = positions[msg.sender][marketId];
        if (pos.size == 0 || baseAmount == 0) revert PositionSizeZero();
        if (baseAmount > pos.size) revert InsufficientCollateral();

        // Settle funding first
        _settleFunding(msg.sender, marketId);

        // Counter swap on vAMM (opposite side)
        Side exitSide = pos.side == Side.LONG ? Side.SHORT : Side.LONG;
        uint256 quoteReceived;
        (quoteReceived, executionPrice) = IHyperionVAMM(cfg.vamm).executeSwap(exitSide, baseAmount);

        // Verify slippage
        if (pos.side == Side.LONG && executionPrice < minSlippagePrice) revert SlippageExceeded();
        if (pos.side == Side.SHORT && executionPrice > minSlippagePrice) revert SlippageExceeded();

        // Calculate proportional open notional being closed
        uint256 notionalClosed = pos.openNotional.wadMul(baseAmount.wadDiv(pos.size));

        // Realized PnL:
        // Long: quoteReceived - notionalClosed
        // Short: notionalClosed - quoteReceived
        if (pos.side == Side.LONG) {
            realizedPnL = int256(quoteReceived) - int256(notionalClosed);
        } else {
            realizedPnL = int256(notionalClosed) - int256(quoteReceived);
        }

        // Deduct taker fee on exit
        uint256 exitFee = quoteReceived.wadMul(cfg.takerFeeRate);
        realizedPnL -= int256(exitFee);

        // Update Open Interest
        if (pos.side == Side.LONG) {
            longOpenInterest[marketId] -= baseAmount;
        } else {
            shortOpenInterest[marketId] -= baseAmount;
        }

        // Update position size and open notional
        pos.size -= baseAmount;
        pos.openNotional -= notionalClosed;
        pos.lastUpdatedTimestamp = block.timestamp;

        // Apply realized PnL to margin engine
        IHyperionMargin(marginEngine).settleRealizedPnL(msg.sender, realizedPnL);

        if (pos.size == 0) {
            emit PositionClosed(msg.sender, marketId, pos.side, baseAmount, realizedPnL, executionPrice);
        } else {
            emit PositionModified(
                msg.sender, marketId, pos.side, pos.size, pos.openNotional, realizedPnL, executionPrice
            );
        }
    }

    /// @inheritdoc IHyperionClearingHouse
    function reducePositionForLiquidation(address account, uint256 marketId, uint256 closedSize)
        external
        override
        nonReentrant
        returns (uint256 remainingSize)
    {
        if (msg.sender != liquidator && msg.sender != owner) revert UnauthorizedCaller();
        Position storage pos = positions[account][marketId];
        if (pos.size == 0) return 0;

        if (closedSize > pos.size) {
            closedSize = pos.size;
        }

        uint256 notionalClosed = pos.size > 0 ? pos.openNotional.wadMul(closedSize.wadDiv(pos.size)) : 0;
        pos.size -= closedSize;
        pos.openNotional -= notionalClosed;
        pos.lastUpdatedTimestamp = block.timestamp;

        if (pos.side == Side.LONG) {
            longOpenInterest[marketId] =
                longOpenInterest[marketId] >= closedSize ? longOpenInterest[marketId] - closedSize : 0;
        } else {
            shortOpenInterest[marketId] =
                shortOpenInterest[marketId] >= closedSize ? shortOpenInterest[marketId] - closedSize : 0;
        }

        if (pos.size == 0) {
            emit PositionClosed(account, marketId, pos.side, closedSize, 0, 0);
        } else {
            emit PositionModified(account, marketId, pos.side, pos.size, pos.openNotional, 0, 0);
        }

        return pos.size;
    }

    /// @inheritdoc IHyperionClearingHouse
    function settleFunding(address account, uint256 marketId) external override returns (int256) {
        return _settleFunding(account, marketId);
    }

    // =========================================================================
    // VIEWS
    // =========================================================================

    /// @inheritdoc IHyperionClearingHouse
    function getPosition(address account, uint256 marketId) external view override returns (Position memory) {
        return positions[account][marketId];
    }

    /// @inheritdoc IHyperionClearingHouse
    function getUnrealizedPnL(address account, uint256 marketId) public view override returns (int256 upnl) {
        Position memory pos = positions[account][marketId];
        if (pos.size == 0) return 0;

        MarketConfig memory cfg = marketConfigs[marketId];
        uint256 markPrice = IHyperionVAMM(cfg.vamm).getSpotPrice();
        uint256 currentNotional = pos.size.wadMul(markPrice);

        if (pos.side == Side.LONG) {
            upnl = int256(currentNotional) - int256(pos.openNotional);
        } else {
            upnl = int256(pos.openNotional) - int256(currentNotional);
        }
    }

    /// @inheritdoc IHyperionClearingHouse
    function getMarketConfig(uint256 marketId) external view override returns (MarketConfig memory) {
        return marketConfigs[marketId];
    }

    /// @inheritdoc IHyperionClearingHouse
    function getOpenInterest(uint256 marketId) external view override returns (uint256, uint256) {
        return (longOpenInterest[marketId], shortOpenInterest[marketId]);
    }

    // =========================================================================
    // INTERNAL SETTLEMENT HELPERS
    // =========================================================================

    function _settleFunding(address account, uint256 marketId) internal returns (int256 fundingPayment) {
        Position storage pos = positions[account][marketId];
        if (pos.size == 0) return 0;

        int256 currentCumFunding = IHyperionFundingController(fundingController).getCumulativeFundingRate(marketId);
        int256 deltaFunding = currentCumFunding - pos.lastCumulativeFunding;

        if (deltaFunding != 0) {
            // Funding debt: (size * deltaFunding) / RAY
            // For LONG: if deltaFunding > 0, long pays funding (+payment)
            // For SHORT: if deltaFunding > 0, short receives funding (-payment)
            int256 debtRay = int256(pos.size) * deltaFunding;
            int256 debtWad = debtRay / RAY;

            fundingPayment = pos.side == Side.LONG ? debtWad : -debtWad;

            // Apply funding payment to account margin: payment > 0 means account pays (deduct)
            IHyperionMargin(marginEngine).settleRealizedPnL(account, -fundingPayment);
            pos.lastCumulativeFunding = currentCumFunding;

            emit FundingSettled(account, marketId, fundingPayment, currentCumFunding);
        }
    }
}
