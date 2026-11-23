// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHyperionMargin} from "../interfaces/IHyperionMargin.sol";
import {IHyperionClearingHouse} from "../interfaces/IHyperionClearingHouse.sol";
import {IHyperionOracleRelay} from "../interfaces/IHyperionOracleRelay.sol";
import {WadRayMath} from "../libraries/WadRayMath.sol";
import {SignedMath} from "../libraries/SignedMath.sol";
import {TransientStorage} from "../libraries/TransientStorage.sol";

/**
 * @title HyperionMargin
 * @notice Multi-collateral margin repository and portfolio solvency evaluator.
 * @dev Manages ERC-20 collateral deposits, haircut-discounted valuations, health factors, and liquidations.
 */
contract HyperionMargin is IHyperionMargin {
    using SafeERC20 for IERC20;
    using WadRayMath for uint256;
    using SignedMath for int256;

    // =========================================================================
    // IMMUTABLES & CONSTANTS
    // =========================================================================

    address public immutable owner;
    address public clearingHouse;
    address public liquidator;
    address public oracleRelay;

    uint256 internal constant WAD = 1e18;
    uint256 public constant MAX_COLLATERAL_ASSETS = 16;

    // =========================================================================
    // STATE VARIABLES
    // =========================================================================

    // List of registered collateral tokens
    address[] public collateralTokens;
    // Token => Collateral configuration
    mapping(address => CollateralConfig) public collateralConfigs;

    // Account => Token => Deposited raw amount
    mapping(address => mapping(address => uint256)) public deposits;

    // Account => Token => Total deposit cap utilized
    mapping(address => uint256) public totalDepositedPerToken;

    // Account => MarketId => Isolated margin allocation (Wad)
    mapping(address => mapping(uint256 => uint256)) public isolatedMargin;

    // Account => Accumulated realized PnL adjustments (Wad)
    mapping(address => int256) public realizedPnLAdjustments;

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert UnauthorizedCaller();
        _;
    }

    modifier onlyClearingHouse() {
        if (msg.sender != clearingHouse) revert UnauthorizedCaller();
        _;
    }

    modifier onlyClearingHouseOrLiquidator() {
        if (msg.sender != clearingHouse && msg.sender != liquidator) revert UnauthorizedCaller();
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
    // CONFIGURATION FUNCTIONS
    // =========================================================================

    /**
     * @notice Sets authorized ClearingHouse, Liquidator, and OracleRelay addresses.
     */
    function setSystemAddresses(address _clearingHouse, address _liquidator, address _oracleRelay) external onlyOwner {
        if (_clearingHouse == address(0) || _liquidator == address(0) || _oracleRelay == address(0)) {
            revert ZeroAddress();
        }
        clearingHouse = _clearingHouse;
        liquidator = _liquidator;
        oracleRelay = _oracleRelay;
    }

    /**
     * @notice Registers or updates a collateral asset configuration.
     */
    function configureCollateral(address token, uint8 decimals, uint256 haircut, uint256 depositCap, bool isAllowed)
        external
        onlyOwner
    {
        if (token == address(0)) revert ZeroAddress();
        if (haircut > WAD) revert InvalidMarket();

        if (collateralConfigs[token].token == address(0)) {
            if (collateralTokens.length >= MAX_COLLATERAL_ASSETS) revert ArrayLengthMismatch();
            collateralTokens.push(token);
        }

        collateralConfigs[token] = CollateralConfig({
            token: token, decimals: decimals, haircut: haircut, depositCap: depositCap, isAllowed: isAllowed
        });

        emit CollateralAssetConfigured(token, haircut, depositCap, isAllowed);
    }

    // =========================================================================
    // DEPOSIT & WITHDRAWAL
    // =========================================================================

    /// @inheritdoc IHyperionMargin
    function depositCollateral(address token, uint256 amount)
        external
        override
        nonReentrant
        returns (uint256 creditValue)
    {
        CollateralConfig memory cfg = collateralConfigs[token];
        if (!cfg.isAllowed) revert InvalidMarket();
        if (amount == 0) revert ZeroAmount();

        if (totalDepositedPerToken[token] + amount > cfg.depositCap) revert ExceedsMaxOpenInterest();

        totalDepositedPerToken[token] += amount;
        deposits[msg.sender][token] += amount;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        creditValue = _calculateTokenCredit(token, amount, cfg);
        emit CollateralDeposited(msg.sender, token, amount, creditValue);
    }

    /// @inheritdoc IHyperionMargin
    function withdrawCollateral(address token, uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (deposits[msg.sender][token] < amount) revert InsufficientCollateral();

        // Calculate credit reduction
        CollateralConfig memory cfg = collateralConfigs[token];
        uint256 creditReduction = _calculateTokenCredit(token, amount, cfg);

        uint256 freeMargin = getFreeMargin(msg.sender);
        if (creditReduction > freeMargin) revert InsufficientFreeMargin();

        deposits[msg.sender][token] -= amount;
        totalDepositedPerToken[token] -= amount;

        IERC20(token).safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, token, amount, creditReduction);
    }

    // =========================================================================
    // SOLVENCY & VALUATION VIEWS
    // =========================================================================

    /// @inheritdoc IHyperionMargin
    function getCollateralBalance(address account, address token) external view override returns (uint256) {
        return deposits[account][token];
    }

    /// @inheritdoc IHyperionMargin
    function getTotalCollateralValue(address account) public view override returns (uint256 totalCredit) {
        uint256 len = collateralTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address token = collateralTokens[i];
            uint256 balance = deposits[account][token];
            if (balance > 0) {
                CollateralConfig memory cfg = collateralConfigs[token];
                totalCredit += _calculateTokenCredit(token, balance, cfg);
            }
        }
    }

    /// @inheritdoc IHyperionMargin
    function getAccountEquity(address account) public view override returns (int256 equity) {
        uint256 collateralVal = getTotalCollateralValue(account);
        int256 baseEquity = int256(collateralVal) + realizedPnLAdjustments[account];

        // Query unrealized PnL from ClearingHouse
        if (clearingHouse != address(0) && clearingHouse.code.length > 0) {
            // Check cross-margin positions
            // Sum uPnL across registered markets
            uint256 marketCount = _getActiveMarketCount();
            for (uint256 m = 1; m <= marketCount; m++) {
                try IHyperionClearingHouse(clearingHouse).getUnrealizedPnL(account, m) returns (int256 upnl) {
                    baseEquity += upnl;
                } catch {}
            }
        }

        return baseEquity;
    }

    /// @inheritdoc IHyperionMargin
    function getTotalInitialMargin(address account) public view override returns (uint256 totalIMR) {
        if (clearingHouse == address(0) || clearingHouse.code.length == 0) return 0;
        uint256 marketCount = _getActiveMarketCount();
        for (uint256 m = 1; m <= marketCount; m++) {
            try IHyperionClearingHouse(clearingHouse).getPosition(account, m) returns (Position memory pos) {
                if (pos.size > 0) {
                    MarketConfig memory mCfg = IHyperionClearingHouse(clearingHouse).getMarketConfig(m);
                    totalIMR += pos.openNotional.wadMul(mCfg.initialMarginRatio);
                }
            } catch {}
        }
    }

    /// @inheritdoc IHyperionMargin
    function getTotalMaintenanceMargin(address account) public view override returns (uint256 totalMMR) {
        if (clearingHouse == address(0) || clearingHouse.code.length == 0) return 0;
        uint256 marketCount = _getActiveMarketCount();
        for (uint256 m = 1; m <= marketCount; m++) {
            try IHyperionClearingHouse(clearingHouse).getPosition(account, m) returns (Position memory pos) {
                if (pos.size > 0) {
                    MarketConfig memory mCfg = IHyperionClearingHouse(clearingHouse).getMarketConfig(m);
                    totalMMR += pos.openNotional.wadMul(mCfg.maintenanceMarginRatio);
                }
            } catch {}
        }
    }

    /// @inheritdoc IHyperionMargin
    function getFreeMargin(address account) public view override returns (uint256 freeMargin) {
        int256 equity = getAccountEquity(account);
        if (equity <= 0) return 0;

        uint256 imr = getTotalInitialMargin(account);
        uint256 uEquity = uint256(equity);

        if (uEquity > imr) {
            return uEquity - imr;
        }
        return 0;
    }

    /// @inheritdoc IHyperionMargin
    function getHealthFactor(address account) public view override returns (uint256 healthFactor) {
        uint256 mmr = getTotalMaintenanceMargin(account);
        if (mmr == 0) return type(uint256).max;

        int256 equity = getAccountEquity(account);
        if (equity <= 0) return 0;

        return uint256(equity).wadDiv(mmr);
    }

    // =========================================================================
    // CLEARING & LIQUIDATION MUTATORS
    // =========================================================================

    /// @inheritdoc IHyperionMargin
    function seizeCollateral(address account, address recipient, address token, uint256 amount)
        external
        override
        onlyClearingHouseOrLiquidator
        nonReentrant
    {
        if (deposits[account][token] < amount) revert InsufficientCollateral();

        deposits[account][token] -= amount;
        totalDepositedPerToken[token] -= amount;

        IERC20(token).safeTransfer(recipient, amount);
    }

    /// @inheritdoc IHyperionMargin
    function settleRealizedPnL(address account, int256 pnlDelta) external override onlyClearingHouseOrLiquidator {
        realizedPnLAdjustments[account] += pnlDelta;
    }

    // =========================================================================
    // INTERNAL VALUATION HELPERS
    // =========================================================================

    function _getActiveMarketCount() internal view returns (uint256) {
        try IHyperionClearingHouse(clearingHouse).marketCount() returns (uint256 registeredCount) {
            return registeredCount > 0 ? registeredCount : 5;
        } catch {
            return 5;
        }
    }

    function _calculateTokenCredit(
        address,
        /*token*/
        uint256 rawAmount,
        CollateralConfig memory cfg
    )
        internal
        pure
        returns (uint256 creditWad)
    {
        // Normalize token decimals to Wad (18 decimals)
        uint256 normalizedAmount;
        if (cfg.decimals < 18) {
            normalizedAmount = rawAmount * (10 ** (18 - cfg.decimals));
        } else if (cfg.decimals > 18) {
            normalizedAmount = rawAmount / (10 ** (cfg.decimals - 18));
        } else {
            normalizedAmount = rawAmount;
        }

        // Apply haircut discount
        creditWad = normalizedAmount.wadMul(cfg.haircut);
    }
}
