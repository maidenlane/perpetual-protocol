// SPDX-License-Identifier: BSD-3-CLAUSE
pragma solidity 0.6.9;
pragma experimental ABIEncoderV2;

import { BaseRelayRecipient } from "@opengsn/gsn/contracts/BaseRelayRecipient.sol";
import { ContextUpgradeSafe } from "@openzeppelin/contracts-ethereum-package/contracts/GSN/Context.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ReentrancyGuardUpgradeSafe
} from "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";
import { OwnerPausableUpgradeSafe } from "./OwnerPausable.sol";
import { MixedDecimal, SignedDecimal, Decimal } from "./utils/MixedDecimal.sol";
import { BlockContext } from "./utils/BlockContext.sol";
import { IAmm } from "./interface/IAmm.sol";
import { DecimalERC20 } from "./utils/DecimalERC20.sol";
import { IMultiTokenRewardRecipient } from "./interface/IMultiTokenRewardRecipient.sol";
import { IInsuranceFund } from "./interface/IInsuranceFund.sol";

// note BaseRelayRecipient must come after OwnerPausableUpgradeSafe so its _msgSender() takes precedence
// (yes, the ordering is reversed comparing to Python)
contract ClearingHouse is
    DecimalERC20,
    OwnerPausableUpgradeSafe,
    ReentrancyGuardUpgradeSafe,
    BlockContext,
    BaseRelayRecipient
{
    using Decimal for Decimal.decimal;
    using SignedDecimal for SignedDecimal.signedDecimal;
    using MixedDecimal for SignedDecimal.signedDecimal;

    //
    // EVENTS
    //
    event MarginRatioChanged(uint256 marginRatio);
    event LiquidationFeeRatioChanged(uint256 liquidationFeeRatio);
    event MarginAdded(address sender, address amm, uint256 amount);
    event MarginRemoved(address sender, address amm, uint256 amount, int256 marginRatio);
    event PositionAdjusted(
        address amm,
        address trader,
        uint256 newPositionSize,
        uint256 oldLiquidityBasis,
        uint256 newLiquidityBasis
    );
    event PositionSettled(address amm, address trader, uint256 valueTransferred);
    event Deposited(address token, address trader, uint256 amount);
    event RestrictionModeEntered(address amm, uint256 blockNumber);

    /// @notice This event is emitted when position change
    /// @param trader the address which execute this transaction
    /// @param amm IAmm address
    /// @param side long or short
    /// @param positionNotional margin * leverage
    /// @param exchangedPositionSize position size, e.g. ETHUSDC or LINKUSDC
    /// @param fee transaction fee
    /// @param positionSizeAfter position size after this transaction, might be increased or decreased
    /// @param realizedPnl realized pnl after this position changed
    /// @param badDebt position change amount cleared by insurance funds
    /// @param liquidationPenalty amount of remaining margin lost due to liquidation
    /// @param quoteAssetReserve quote asset reserve after this event, e.g. USDC
    /// @param baseAssetReserve base asset reserve after this event, e.g. ETHUSDC, LINKUSDC
    event PositionChanged(
        address trader,
        address amm,
        Side side,
        uint256 positionNotional,
        uint256 exchangedPositionSize,
        uint256 fee,
        int256 positionSizeAfter,
        int256 realizedPnl,
        uint256 badDebt,
        uint256 liquidationPenalty,
        uint256 quoteAssetReserve,
        uint256 baseAssetReserve
    );

    /// @notice This event is emitted when position liquidated
    /// @param trader the account address being liquidated
    /// @param amm IAmm address
    /// @param positionNotional liquidated position value minus liquidationFee
    /// @param positionSize liquidated position size
    /// @param liquidationFee liquidation fee to the liquidator
    /// @param liquidator the address which execute this transaction
    /// @param badDebt liquidation fee amount cleared by insurance funds
    event PositionLiquidated(
        address trader,
        address amm,
        uint256 positionNotional,
        uint256 positionSize,
        uint256 liquidationFee,
        address liquidator,
        uint256 badDebt
    );

    //
    // Struct and Enum
    //

    enum Side { BUY, SELL }
    enum PnlCalcOption { SPOT_PRICE, TWAP }

    /// @notice This struct records personal position information
    /// @param size denominated in amm.baseAsset
    /// @param margin isolated margin
    /// @param openNotional the quoteAsset value of position when opening position. the cost of the position
    /// @param lastUpdatedCumulativePremiumFraction for calculating funding payment, record at the moment every time when trader open/reduce/close position
    /// @param liquidityBasis amm.liquidityMultiplier when the position is updated
    /// @param blockNumber the block number of the last position
    struct Position {
        SignedDecimal.signedDecimal size;
        Decimal.decimal margin;
        Decimal.decimal openNotional;
        SignedDecimal.signedDecimal lastUpdatedCumulativePremiumFraction;
        Decimal.decimal liquidityBasis;
        uint256 blockNumber;
    }

    /// @notice This struct is used for avoiding stack too deep error when passing too many var between functions
    struct PositionResp {
        Position position;
        // the quote asset amount trader will send if open position, will receive if close
        Decimal.decimal exchangedQuoteAssetAmount;
        // if realizedPnl + realizedFundingPayment + margin is negative, it's the abs value of it
        Decimal.decimal badDebt;
        // the base asset amount trader will receive if open position, will send if close
        SignedDecimal.signedDecimal exchangedPositionSize;
        // realizedPnl = unrealizedPnl * closedRatio
        SignedDecimal.signedDecimal realizedPnl;
        // positive = trader transfer margin to vault, negative = trader receive margin from vault
        // it's 0 when internalReducePosition, its addedMargin when internalIncreasePosition
        // it's min(0, oldPosition + realizedFundingPayment + realizedPnl) when internalClosePosition
        SignedDecimal.signedDecimal marginToVault;
    }

    struct AmmMap {
        // issue #1471
        // last block when it turn restriction mode on.
        // In restriction mode, no one can do multi open/close/liquidate position in the same block.
        // If any underwater position being closed (having a bad debt and make insuranceFund loss),
        // or any liquidation happened,
        // restriction mode is ON in that block and OFF(default) in the next block.
        // This design is to prevent the attacker being benefited from the multiple action in one block
        // in extreme cases
        uint256 lastRestrictionBlock;
        SignedDecimal.signedDecimal[] cumulativePremiumFractions;
        mapping(address => Position) positionMap;
    }

    //**********************************************************//
    //    Can not change the order of below state variables     //
    //**********************************************************//
    //prettier-ignore
    string public override versionRecipient;

    /**
     * Following 3 states are able to be updated by DAO
     */
    Decimal.decimal public initMarginRatio;
    Decimal.decimal public maintenanceMarginRatio;
    Decimal.decimal public liquidationFeeRatio;

    // key by amm address
    mapping(address => AmmMap) internal ammMap;

    // designed for arbitragers who can hold unlimited positions
    mapping(address => bool) private whitelistMap;

    // prepaid bad debt balance, key by ERC20 token address
    mapping(address => Decimal.decimal) private prepaidBadDebt;

    // contract dependencies
    IInsuranceFund public insuranceFund;
    IMultiTokenRewardRecipient public feePool;

    //**********************************************************//
    //    Can not change the order of above state variables     //
    //**********************************************************//

    //◥◤◥◤◥◤◥◤◥◤◥◤◥◤◥◤ add state variables below ◥◤◥◤◥◤◥◤◥◤◥◤◥◤◥◤//

    //◢◣◢◣◢◣◢◣◢◣◢◣◢◣◢◣ add state variables above ◢◣◢◣◢◣◢◣◢◣◢◣◢◣◢◣//
    uint256[50] private __gap;

    //
    // FUNCTIONS
    //
    // openzeppelin doesn't support struct input
    // https://github.com/OpenZeppelin/openzeppelin-sdk/issues/1523
    function initialize(
        uint256 _initMarginRatio,
        uint256 _maintenanceMarginRatio,
        uint256 _liquidationFeeRatio,
        IInsuranceFund _insuranceFund,
        address _trustedForwarder
    ) public initializer {
        require(address(_insuranceFund) != address(0), "Invalid IInsuranceFund");

        __OwnerPausable_init();
        __ReentrancyGuard_init();

        versionRecipient = "1.0.0";
        initMarginRatio = Decimal.decimal(_initMarginRatio);
        setMaintenanceMarginRatio(Decimal.decimal(_maintenanceMarginRatio));
        setLiquidationFeeRatio(Decimal.decimal(_liquidationFeeRatio));
        insuranceFund = _insuranceFund;
        trustedForwarder = _trustedForwarder;

        versionRecipient = "1.0.0"; // we are not using it atm
    }

    //
    // External
    //

    /**
     * @notice set liquidation fee ratio
     * @dev only owner can call
     * @param _liquidationFeeRatio new liquidation fee ratio in 18 digits
     */
    function setLiquidationFeeRatio(Decimal.decimal memory _liquidationFeeRatio) public onlyOwner {
        liquidationFeeRatio = _liquidationFeeRatio;
        emit LiquidationFeeRatioChanged(liquidationFeeRatio.toUint());
    }

    /**
     * @notice set maintenance margin ratio
     * @dev only owner can call
     * @param _maintenanceMarginRatio new maintenance margin ratio in 18 digits
     */
    function setMaintenanceMarginRatio(Decimal.decimal memory _maintenanceMarginRatio) public onlyOwner {
        maintenanceMarginRatio = _maintenanceMarginRatio;
        emit MarginRatioChanged(maintenanceMarginRatio.toUint());
    }

    // TODO add event
    function setFeePool(IMultiTokenRewardRecipient _feePool) external onlyOwner {
        feePool = _feePool;
    }

    // TODO add event
    /**
     * @notice add an address in the whitelist. People in the whitelist can hold unlimited positions.
     * @dev only owner can call
     * @param _addr an address
     */
    function addToWhitelists(address _addr) external onlyOwner {
        whitelistMap[_addr] = true;
    }

    // TODO add event
    function removeFromWhitelists(address _addr) external onlyOwner {
        delete whitelistMap[_addr];
    }

    /**
     * @notice add margin to increase margin ratio
     * @param _amm IAmm address
     * @param _addedMargin added margin in 18 digits
     */
    function addMargin(IAmm _amm, Decimal.decimal calldata _addedMargin) external whenNotPaused() nonReentrant() {
        // check condition
        requireAmm(_amm, true);
        requireNonZeroInput(_addedMargin);

        // update margin part in personal position
        address trader = _msgSender();
        updateMargin(_amm, trader, MixedDecimal.fromDecimal(_addedMargin));

        // transfer token from trader
        _transferFrom(_amm.quoteAsset(), trader, address(this), _addedMargin);

        // emit event
        emit MarginAdded(trader, address(_amm), _addedMargin.toUint());
    }

    /**
     * @notice remove margin to decrease margin ratio
     * @param _amm IAmm address
     * @param _removedMargin removed margin in 18 digits
     */
    function removeMargin(IAmm _amm, Decimal.decimal calldata _removedMargin) external whenNotPaused() nonReentrant() {
        // check condition
        requireAmm(_amm, true);
        requireNonZeroInput(_removedMargin);

        // update margin part in personal position, and get new margin
        address trader = _msgSender();
        updateMargin(_amm, trader, MixedDecimal.fromDecimal(_removedMargin).mulScalar(-1));

        // check margin ratio
        SignedDecimal.signedDecimal memory marginRatio = getMarginRatio(_amm, trader);
        requireEnoughMarginRatio(marginRatio);

        // transfer token back to trader
        withdraw(_amm.quoteAsset(), trader, _removedMargin);

        // emit event
        emit MarginRemoved(trader, address(_amm), _removedMargin.toUint(), marginRatio.toInt());
    }

    /**
     * @notice settle all the positions when amm is shutdown. The settlement price is according to IAmm.settlementPrice
     * @param _amm IAmm address
     */
    function settlePosition(IAmm _amm) external nonReentrant() {
        // check condition
        requireAmm(_amm, false);

        address trader = _msgSender();
        Position memory pos = getPosition(_amm, trader);
        requirePositionSize(pos.size);

        // update position
        clearPosition(_amm, trader);

        // calculate settledValue
        // If Settlement Price = 0, everyone takes back her collateral.
        // else Returned Fund = Position Size * (Settlement Price - Open Price) + Collateral
        Decimal.decimal memory settlementPrice = _amm.getSettlementPrice();
        Decimal.decimal memory settledValue;
        if (settlementPrice.toUint() == 0) {
            settledValue = pos.margin;
        } else {
            SignedDecimal.signedDecimal memory signedSettlePrice = SignedDecimal.signedDecimal(
                int256(settlementPrice.toUint())
            );
            Decimal.decimal memory openPrice = pos.openNotional.divD(pos.size.abs());
            SignedDecimal.signedDecimal memory returnedFund = pos.size.mulD(signedSettlePrice.subD(openPrice)).addD(
                pos.margin
            );
            // if `returnedFund` is negative, trader can't get anything back
            if (returnedFund.toInt() > 0) {
                settledValue = returnedFund.abs();
            }
        }

        // transfer token based on settledValue
        if (settledValue.toUint() != 0) {
            IERC20 quoteAsset = _amm.quoteAsset();
            withdraw(quoteAsset, trader, settledValue);
        }

        // emit event
        emit PositionSettled(address(_amm), trader, settledValue.toUint());
    }

    // if increase position
    //   marginToVault = addMargin
    //   marginDiff = realizedFundingPayment + realizedPnl(0)
    //   pos.margin += marginToVault + marginDiff
    //   vault.margin += marginToVault + marginDiff
    //   required(enoughMarginRatio)
    // else if reduce position()
    //   marginToVault = 0
    //   marginDiff = realizedFundingPayment + realizedPnl
    //   pos.margin += marginToVault + marginDiff
    //   if pos.margin < 0, badDebt = abs(pos.margin), set pos.margin = 0
    //   vault.margin += marginToVault + marginDiff
    //   required(enoughMarginRatio)
    // else if close
    //   marginDiff = realizedFundingPayment + realizedPnl
    //   pos.margin += marginDiff
    //   if pos.margin < 0, badDebt = abs(pos.margin)
    //   marginToVault = -pos.margin
    //   set pos.margin = 0
    //   vault.margin += marginToVault + marginDiff
    // else if close and open a larger position in reverse side
    //   close()
    //   positionNotional -= exchangedQuoteAssetAmount
    //   newMargin = positionNotional / leverage
    //   internalIncreasePosition(newMargin, leverage)
    // else if liquidate
    //   close()
    //   pay liquidation fee to liquidator
    //   move the remain margin to insuranceFund
    /**
     * @notice open a position
     * @param _amm amm address
     * @param _side enum Side; BUY for long and SELL for short
     * @param _quoteAssetAmount quote asset amount in 18 digits. Can Not be 0
     * @param _leverage leverage  in 18 digits. Can Not be 0
     * @param _baseAssetAmountLimit minimum base asset amount expected to get to prevent from slippage.
     */
    function openPosition(
        IAmm _amm,
        Side _side,
        Decimal.decimal calldata _quoteAssetAmount,
        Decimal.decimal calldata _leverage,
        Decimal.decimal calldata _baseAssetAmountLimit
    ) external whenNotPaused() nonReentrant() {
        requireAmm(_amm, true);
        requireNonZeroInput(_quoteAssetAmount);
        requireNonZeroInput(_leverage);
        requireEnoughMarginRatio(MixedDecimal.fromDecimal(Decimal.one()).divD(_leverage));
        requireNotRestrictionMode(_amm);

        PositionResp memory positionResp;
        address trader = _msgSender();
        {
            // add scope for stack too deep error
            int256 oldPositionSize = adjustPositionForLiquidityChanged(_amm, trader).size.toInt();

            // increase or decrease position depends on old position's side and size
            if (oldPositionSize == 0 || (oldPositionSize > 0 ? Side.BUY : Side.SELL) == _side) {
                positionResp = internalIncreasePosition(
                    _amm,
                    _side,
                    _quoteAssetAmount.mulD(_leverage),
                    _baseAssetAmountLimit,
                    _leverage
                );
            } else {
                positionResp = openReversePosition(_amm, _side, _quoteAssetAmount, _leverage, _baseAssetAmountLimit);
            }

            // update the position state
            setPosition(_amm, trader, positionResp.position);

            // to prevent attacker to leverage the bad debt to withdraw extra token from  insurance fund
            if (positionResp.badDebt.toUint() > 0) {
                enterRestrictionMode(_amm);
            }

            // transfer the actual token between trader and vault
            IERC20 quoteToken = _amm.quoteAsset();
            if (positionResp.marginToVault.toInt() > 0) {
                _transferFrom(quoteToken, trader, address(this), positionResp.marginToVault.abs());
            } else if (positionResp.marginToVault.toInt() < 0) {
                withdraw(quoteToken, trader, positionResp.marginToVault.abs());
            }
        }

        // calculate fee and transfer token for fees
        //@audit - can optimize by changing amm.swapInput/swapOutput's return type to (exchangedAmount, quoteToll, quoteSpread, quoteReserve, baseReserve) (@wraecca)
        Decimal.decimal memory transferredFee = transferFee(trader, _amm, positionResp.exchangedQuoteAssetAmount);

        // emit event
        (Decimal.decimal memory quoteAssetReserve, Decimal.decimal memory baseAssetReserve) = _amm.getReserve();
        emit PositionChanged(
            trader,
            address(_amm),
            _side,
            positionResp.exchangedQuoteAssetAmount.toUint(),
            positionResp.exchangedPositionSize.toUint(),
            transferredFee.toUint(),
            positionResp.position.size.toInt(),
            positionResp.realizedPnl.toInt(),
            positionResp.badDebt.toUint(),
            0,
            quoteAssetReserve.toUint(),
            baseAssetReserve.toUint()
        );
    }

    /**
     * @notice close all the positions
     * @param _amm IAmm address
     */
    function closePosition(IAmm _amm, Decimal.decimal calldata _quoteAssetAmountLimit)
        external
        whenNotPaused()
        nonReentrant()
    {
        // check conditions
        requireAmm(_amm, true);
        requireNotRestrictionMode(_amm);

        // update position
        address trader = _msgSender();
        adjustPositionForLiquidityChanged(_amm, trader);
        PositionResp memory positionResp = internalClosePosition(_amm, trader, _quoteAssetAmountLimit, true);

        {
            // add scope for stack too deep error
            // transfer the actual token from trader and vault
            IERC20 quoteToken = _amm.quoteAsset();
            if (positionResp.badDebt.toUint() > 0) {
                enterRestrictionMode(_amm);
                realizeBadDebt(quoteToken, positionResp.badDebt);
            }
            withdraw(quoteToken, trader, positionResp.marginToVault.abs());
        }

        // calculate fee and transfer token for fees
        Decimal.decimal memory transferredFee = transferFee(trader, _amm, positionResp.exchangedQuoteAssetAmount);

        // prepare event
        (Decimal.decimal memory quoteAssetReserve, Decimal.decimal memory baseAssetReserve) = _amm.getReserve();
        emit PositionChanged(
            trader,
            address(_amm),
            positionResp.exchangedPositionSize.toInt() > 0 ? Side.SELL : Side.BUY,
            positionResp.exchangedQuoteAssetAmount.toUint(),
            positionResp.exchangedPositionSize.toUint(),
            transferredFee.toUint(),
            positionResp.position.size.toInt(),
            positionResp.realizedPnl.toInt(),
            positionResp.badDebt.toUint(),
            0,
            quoteAssetReserve.toUint(),
            baseAssetReserve.toUint()
        );
    }

    /**
     * @notice liquidate trader's underwater position. Require trader's margin ratio less than maintenance margin ratio
     * @dev liquidator can NOT open any positions in the same block to prevent from price manipulation.
     * @param _amm IAmm address
     * @param _trader trader address
     */
    function liquidate(IAmm _amm, address _trader) external nonReentrant() {
        // check conditions
        requireAmm(_amm, true);
        require(
            getMarginRatio(_amm, _trader).subD(maintenanceMarginRatio).toInt() < 0,
            "Margin ratio is larger than min requirement"
        );

        address liquidator = _msgSender();

        // update states
        address ammAddr = address(_amm);
        adjustPositionForLiquidityChanged(_amm, _trader);
        PositionResp memory positionResp = internalClosePosition(_amm, _trader, Decimal.zero(), false);

        enterRestrictionMode(_amm);

        // Amount pay to liquidator
        Decimal.decimal memory liquidationFee = positionResp.exchangedQuoteAssetAmount.mulD(liquidationFeeRatio);
        // neither trader nor liquidator should pay anything for liquidating position
        // in here, -marginToVault means remainMargin
        Decimal.decimal memory remainMargin = positionResp.marginToVault.abs();

        // if the remainMargin is not enough for liquidationFee, count it as bad debt
        // else, then the rest will be transferred to insuranceFund
        Decimal.decimal memory liquidationBadDebt;
        {
            // add scope for stack too deep error
            Decimal.decimal memory totalBadDebt = positionResp.badDebt;
            SignedDecimal.signedDecimal memory totalMarginToVault = positionResp.marginToVault;
            if (liquidationFee.toUint() > remainMargin.toUint()) {
                liquidationBadDebt = liquidationFee.subD(remainMargin);
                totalBadDebt = totalBadDebt.addD(liquidationBadDebt);
            } else {
                totalMarginToVault = totalMarginToVault.addD(liquidationFee);
            }

            // transfer the actual token between trader and vault
            IERC20 quoteAsset = _amm.quoteAsset();
            if (totalBadDebt.toUint() > 0) {
                realizeBadDebt(quoteAsset, totalBadDebt);
            }
            if (totalMarginToVault.toInt() < 0) {
                transferToInsuranceFund(quoteAsset, totalMarginToVault.abs());
            }
            withdraw(quoteAsset, liquidator, liquidationFee);
        }

        // emit event
        (Decimal.decimal memory quoteAssetReserve, Decimal.decimal memory baseAssetReserve) = _amm.getReserve();
        emit PositionChanged(
            _trader,
            ammAddr,
            positionResp.exchangedPositionSize.toInt() > 0 ? Side.SELL : Side.BUY,
            positionResp.exchangedQuoteAssetAmount.toUint(),
            positionResp.exchangedPositionSize.toUint(),
            0,
            0,
            positionResp.realizedPnl.toInt(),
            positionResp.badDebt.toUint(),
            remainMargin.toUint(),
            quoteAssetReserve.toUint(),
            baseAssetReserve.toUint()
        );
        emit PositionLiquidated(
            _trader,
            ammAddr,
            positionResp.exchangedQuoteAssetAmount.toUint(),
            positionResp.exchangedPositionSize.toUint(),
            liquidationFee.toUint(),
            liquidator,
            liquidationBadDebt.toUint()
        );
    }

    /**
     * @notice if funding rate is positive, traders with long position pay traders with short position and vice versa.
     * @param _amm IAmm address
     */
    function payFunding(IAmm _amm) external {
        requireAmm(_amm, true);

        // must copy the baseAssetDeltaThisFundingPeriod first
        SignedDecimal.signedDecimal memory baseAssetDeltaThisFundingPeriod = _amm.getBaseAssetDeltaThisFundingPeriod();

        SignedDecimal.signedDecimal memory premiumFraction = _amm.settleFunding();
        ammMap[address(_amm)].cumulativePremiumFractions.push(
            premiumFraction.addD(getLatestCumulativePremiumFraction(_amm))
        );

        // funding payment = premium fraction * position
        // eg. if alice takes 10 long position, baseAssetDeltaThisFundingPeriod = -10
        // if premiumFraction is positive: long pay short, amm get positive funding payment
        // if premiumFraction is negative: short pay long, amm get negative funding payment
        // if position side * premiumFraction > 0, funding payment is negative which means loss
        SignedDecimal.signedDecimal memory ammFundingPaymentLoss = premiumFraction.mulD(
            baseAssetDeltaThisFundingPeriod
        );

        Decimal.decimal memory ammFundingPaymentLossAbs = ammFundingPaymentLoss.abs();
        IERC20 quoteAsset = _amm.quoteAsset();
        if (ammFundingPaymentLoss.toInt() > 0) {
            insuranceFund.withdraw(quoteAsset, ammFundingPaymentLossAbs);
        } else {
            transferToInsuranceFund(quoteAsset, ammFundingPaymentLossAbs);
        }
    }

    //
    // VIEW FUNCTIONS
    //

    /**
     * @notice get margin ratio, marginRatio = (unrealized Pnl + margin) / openNotional
     * use spot and twap price to calculate unrealized Pnl, final unrealized Pnl depends on which one is higher
     * @param _amm IAmm address
     * @param _trader trader address
     * @return margin ratio in 18 digits
     */
    function getMarginRatio(IAmm _amm, address _trader) public view returns (SignedDecimal.signedDecimal memory) {
        Position memory position = getPosition(_amm, _trader);
        requirePositionSize(position.size);
        requireNonZeroInput(position.openNotional);

        (, SignedDecimal.signedDecimal memory spotPricePnl) = (
            getPositionNotionalAndUnrealizedPnl(_amm, _trader, PnlCalcOption.SPOT_PRICE)
        );
        (, SignedDecimal.signedDecimal memory twapPricePnl) = (
            getPositionNotionalAndUnrealizedPnl(_amm, _trader, PnlCalcOption.TWAP)
        );
        SignedDecimal.signedDecimal memory unrealizedPnl = spotPricePnl.toInt() > twapPricePnl.toInt()
            ? spotPricePnl
            : twapPricePnl;
        return unrealizedPnl.addD(position.margin).divD(position.openNotional);
    }

    /**
     * @notice get personal position information, adjust size based on amm.positionMultiplier
     * @param _amm IAmm address
     * @param _trader trader address
     * @return struct Position
     */
    function getPosition(IAmm _amm, address _trader) public view returns (Position memory) {
        Position memory pos = getUnadjustedPosition(_amm, _trader);
        Decimal.decimal memory cumulativePositionMultiplier = _amm.getCumulativePositionMultiplier();
        if (pos.liquidityBasis.toUint() == cumulativePositionMultiplier.toUint() || pos.size.toInt() == 0) {
            return pos;
        }

        pos.size = pos.size.mulD(cumulativePositionMultiplier).divD(pos.liquidityBasis);
        pos.liquidityBasis = cumulativePositionMultiplier;
        return pos;
    }

    /**
     * @notice get position notional and unrealized Pnl without fee expense and funding payment
     * @param _amm IAmm address
     * @param _trader trader address
     * @param _pnlCalcOption enum PnlCalcOption, SPOT_PRICE for spot price and TWAP for twap price
     * @return positionNotional position notional
     * @return unrealizedPnl unrealized Pnl
     */
    function getPositionNotionalAndUnrealizedPnl(
        IAmm _amm,
        address _trader,
        PnlCalcOption _pnlCalcOption
    ) public view returns (Decimal.decimal memory positionNotional, SignedDecimal.signedDecimal memory unrealizedPnl) {
        Position memory position = getPosition(_amm, _trader);
        if (position.size.toInt() == 0) {
            return (Decimal.zero(), SignedDecimal.zero());
        }
        bool isShortPosition = position.size.toInt() < 0;
        IAmm.Dir dir = isShortPosition ? IAmm.Dir.REMOVE_FROM_AMM : IAmm.Dir.ADD_TO_AMM;
        if (_pnlCalcOption == PnlCalcOption.TWAP) {
            positionNotional = _amm.getOutputTwap(dir, position.size.abs());
        } else {
            positionNotional = _amm.getOutputPrice(dir, position.size.abs());
        }
        // unrealizedPnlForLongPosition = positionNotional - openNotional
        // unrealizedPnlForShortPosition = positionNotionalWhenBorrowed - positionNotionalWhenReturned =
        // openNotional - positionNotional = unrealizedPnlForLongPosition * -1
        unrealizedPnl = isShortPosition
            ? MixedDecimal.fromDecimal(position.openNotional).subD(positionNotional)
            : MixedDecimal.fromDecimal(positionNotional).subD(position.openNotional);
    }

    /**
     * @notice get latest cumulative premium fraction.
     * @param _amm IAmm address
     * @return latest cumulative premium fraction in 18 digits
     */
    function getLatestCumulativePremiumFraction(IAmm _amm) public view returns (SignedDecimal.signedDecimal memory) {
        uint256 len = ammMap[address(_amm)].cumulativePremiumFractions.length;
        if (len == 0) {
            return SignedDecimal.zero();
        }
        return ammMap[address(_amm)].cumulativePremiumFractions[len - 1];
    }

    function getPrepaidBadDebt(address _token) public view returns (Decimal.decimal memory) {
        return prepaidBadDebt[_token];
    }

    function isInWhitelists(address _addr) public view returns (bool) {
        return whitelistMap[_addr];
    }

    //
    // INTERNAL FUNCTIONS
    //

    function enterRestrictionMode(IAmm _amm) internal {
        uint256 blockNumber = _blockNumber();
        ammMap[address(_amm)].lastRestrictionBlock = blockNumber;
        emit RestrictionModeEntered(address(_amm), blockNumber);
    }

    function adjustPositionForLiquidityChanged(IAmm _amm, address _trader) internal returns (Position memory) {
        Position memory unadjustedPosition = getUnadjustedPosition(_amm, _trader);
        Position memory adjustedPosition = getPosition(_amm, _trader);
        if (adjustedPosition.liquidityBasis.toUint() == unadjustedPosition.liquidityBasis.toUint()) {
            return unadjustedPosition;
        }

        setPosition(_amm, _trader, adjustedPosition);
        emit PositionAdjusted(
            address(_amm),
            _trader,
            adjustedPosition.size.toUint(),
            unadjustedPosition.liquidityBasis.toUint(),
            adjustedPosition.liquidityBasis.toUint()
        );
        return adjustedPosition;
    }

    function setPosition(
        IAmm _amm,
        address _trader,
        Position memory _position
    ) internal {
        Position storage positionStorage = ammMap[address(_amm)].positionMap[_trader];
        positionStorage.size = _position.size;
        positionStorage.margin = _position.margin;
        positionStorage.openNotional = _position.openNotional;
        positionStorage.lastUpdatedCumulativePremiumFraction = _position.lastUpdatedCumulativePremiumFraction;
        positionStorage.liquidityBasis = _position.liquidityBasis;
        positionStorage.blockNumber = _position.blockNumber;
    }

    function clearPosition(IAmm _amm, address _trader) internal {
        // keep the record in order to retain the last updated block number
        ammMap[address(_amm)].positionMap[_trader] = Position({
            size: SignedDecimal.zero(),
            margin: Decimal.zero(),
            openNotional: Decimal.zero(),
            lastUpdatedCumulativePremiumFraction: SignedDecimal.zero(),
            liquidityBasis: Decimal.zero(),
            blockNumber: _blockNumber()
        });
    }

    // amm, side, openNotional, minPositionSize, leverage
    function internalIncreasePosition(
        IAmm _amm,
        Side _side,
        Decimal.decimal memory _openNotional,
        Decimal.decimal memory _minPositionSize,
        Decimal.decimal memory _leverage
    ) internal returns (PositionResp memory positionResp) {
        Position memory oldPosition = getUnadjustedPosition(_amm, _msgSender());
        positionResp.exchangedPositionSize = swapInput(_amm, _side, _openNotional, _minPositionSize);
        SignedDecimal.signedDecimal memory newSize = oldPosition.size.addD(positionResp.exchangedPositionSize);
        // if the trader is not in the whitelist, check max position size
        if (!isInWhitelists(_msgSender())) {
            Decimal.decimal memory maxHoldingBaseAsset = _amm.getMaxHoldingBaseAsset();
            if (maxHoldingBaseAsset.toUint() > 0) {
                // total position size should be less than `positionUpperBound`
                require(newSize.abs().cmp(maxHoldingBaseAsset) <= 0, "hit position size upper bound");
            }
        }

        SignedDecimal.signedDecimal memory increaseMarginRequirement = MixedDecimal.fromDecimal(
            _openNotional.divD(_leverage)
        );
        (
            SignedDecimal.signedDecimal memory remainMargin,
            SignedDecimal.signedDecimal memory latestCumulativePremiumFraction,
            Decimal.decimal memory badDebt
        ) = calcRemainMarginWithFundingPayment(_amm, oldPosition, increaseMarginRequirement);

        // update positionResp
        positionResp.badDebt = badDebt;
        positionResp.exchangedQuoteAssetAmount = _openNotional;
        positionResp.realizedPnl = SignedDecimal.zero();
        positionResp.marginToVault = increaseMarginRequirement;
        positionResp.position = Position(
            newSize,
            remainMargin.abs(),
            oldPosition.openNotional.addD(positionResp.exchangedQuoteAssetAmount),
            latestCumulativePremiumFraction,
            oldPosition.liquidityBasis,
            _blockNumber()
        );
    }

    function openReversePosition(
        IAmm _amm,
        Side _side,
        Decimal.decimal memory _quoteAssetAmount,
        Decimal.decimal memory _leverage,
        Decimal.decimal memory _baseAssetAmountLimit
    ) internal returns (PositionResp memory) {
        Decimal.decimal memory openNotional = _quoteAssetAmount.mulD(_leverage);
        (
            Decimal.decimal memory oldPositionNotional,
            SignedDecimal.signedDecimal memory unrealizedPnl
        ) = getPositionNotionalAndUnrealizedPnl(_amm, _msgSender(), PnlCalcOption.SPOT_PRICE);
        PositionResp memory positionResp;

        // reduce position if old position is larger
        if (oldPositionNotional.toUint() > openNotional.toUint()) {
            Position memory oldPosition = getUnadjustedPosition(_amm, _msgSender());
            positionResp.exchangedPositionSize = swapInput(_amm, _side, openNotional, _baseAssetAmountLimit);

            // realizedPnl = unrealizedPnl * closedRatio
            // closedRatio = positionResp.exchangedPositionSiz / oldPosition.size
            positionResp.realizedPnl = (oldPosition.size.toUint() == 0)
                ? SignedDecimal.zero()
                : unrealizedPnl.mulD(positionResp.exchangedPositionSize.abs()).divD(oldPosition.size.abs());
            (
                SignedDecimal.signedDecimal memory remainMargin,
                SignedDecimal.signedDecimal memory latestCumulativePremiumFraction,
                Decimal.decimal memory badDebt
            ) = calcRemainMarginWithFundingPayment(_amm, oldPosition, positionResp.realizedPnl);

            positionResp.badDebt = badDebt;
            positionResp.marginToVault = SignedDecimal.zero();
            positionResp.exchangedQuoteAssetAmount = openNotional;

            // remainUnrealizedPnl = unrealizedPnl - realizedPnl
            SignedDecimal.signedDecimal memory remainUnrealizedPnl = unrealizedPnl.subD(positionResp.realizedPnl);

            // calculate openNotional (it's different depends on long or short side)
            // long: unrealizedPnl = positionNotional - openNotional => openNotional = positionNotional - unrealizedPnl
            // short: unrealizedPnl = openNotional - positionNotional => openNotional = positionNotional + unrealizedPnl
            // positionNotional = oldPositionNotional - exchangedQuoteAssetAmount
            SignedDecimal.signedDecimal memory remainOpenNotional = oldPosition.size.toInt() > 0
                ? MixedDecimal.fromDecimal(oldPositionNotional).subD(positionResp.exchangedQuoteAssetAmount).subD(
                    remainUnrealizedPnl
                )
                : remainUnrealizedPnl.addD(oldPositionNotional).subD(positionResp.exchangedQuoteAssetAmount);
            require(remainOpenNotional.toInt() > 0, "value of openNotional <= 0");

            positionResp.position = Position(
                oldPosition.size.addD(positionResp.exchangedPositionSize),
                remainMargin.abs(),
                remainOpenNotional.abs(),
                latestCumulativePremiumFraction,
                oldPosition.liquidityBasis,
                _blockNumber()
            );
            return positionResp;
        }

        return closeAndOpenReversePosition(_amm, _side, _quoteAssetAmount, _leverage, _baseAssetAmountLimit);
    }

    function closeAndOpenReversePosition(
        IAmm _amm,
        Side _side,
        Decimal.decimal memory _quoteAssetAmount,
        Decimal.decimal memory _leverage,
        Decimal.decimal memory _baseAssetAmountLimit
    ) internal returns (PositionResp memory positionResp) {
        // new position size is larger than or equal to the old position size
        // so either close or close then open a larger position
        PositionResp memory closePositionResp = internalClosePosition(_amm, _msgSender(), Decimal.zero(), true);

        // the old position is underwater. trader should close a position first
        require(closePositionResp.badDebt.toUint() == 0, "reduce an underwater position");

        // update open notional after closing position
        Decimal.decimal memory openNotional = _quoteAssetAmount.mulD(_leverage).subD(
            closePositionResp.exchangedQuoteAssetAmount
        );

        // if remain exchangedQuoteAssetAmount is too small (eg. 1wei) then the required margin might be 0
        // then the clearingHouse will stop opening position
        if (openNotional.divD(_leverage).toUint() == 0) {
            positionResp = closePositionResp;
        } else {
            Decimal.decimal memory updatedBaseAssetAmountLimit = _baseAssetAmountLimit.toUint() >
                closePositionResp.exchangedPositionSize.toUint()
                ? _baseAssetAmountLimit.subD(closePositionResp.exchangedPositionSize.abs())
                : Decimal.zero();
            PositionResp memory increasePositionResp = internalIncreasePosition(
                _amm,
                _side,
                openNotional,
                updatedBaseAssetAmountLimit,
                _leverage
            );
            Decimal.decimal memory exchangedPosSize = closePositionResp.exchangedPositionSize.abs().addD(
                increasePositionResp.exchangedPositionSize.abs()
            );
            positionResp = PositionResp({
                position: increasePositionResp.position,
                exchangedQuoteAssetAmount: closePositionResp.exchangedQuoteAssetAmount.addD(
                    increasePositionResp.exchangedQuoteAssetAmount
                ),
                badDebt: closePositionResp.badDebt.addD(increasePositionResp.badDebt),
                exchangedPositionSize: MixedDecimal.fromDecimal(exchangedPosSize),
                realizedPnl: closePositionResp.realizedPnl.addD(increasePositionResp.realizedPnl),
                marginToVault: closePositionResp.marginToVault.addD(increasePositionResp.marginToVault)
            });
        }
        return positionResp;
    }

    function internalClosePosition(
        IAmm _amm,
        address _trader,
        Decimal.decimal memory _quoteAssetAmountLimit,
        bool _skipFluctuationCheck
    ) private returns (PositionResp memory positionResp) {
        // check conditions
        Position memory oldPosition = getUnadjustedPosition(_amm, _trader);
        SignedDecimal.signedDecimal memory oldPositionSize = oldPosition.size;
        requirePositionSize(oldPositionSize);

        (, SignedDecimal.signedDecimal memory unrealizedPnl) = getPositionNotionalAndUnrealizedPnl(
            _amm,
            _trader,
            PnlCalcOption.SPOT_PRICE
        );
        (
            SignedDecimal.signedDecimal memory remainMargin,
            ,
            Decimal.decimal memory badDebt
        ) = calcRemainMarginWithFundingPayment(_amm, oldPosition, unrealizedPnl);

        positionResp.exchangedPositionSize = oldPositionSize;
        positionResp.realizedPnl = unrealizedPnl;
        positionResp.badDebt = badDebt;
        positionResp.marginToVault = remainMargin.mulScalar(-1);
        positionResp.exchangedQuoteAssetAmount = _amm.swapOutput(
            oldPositionSize.toInt() > 0 ? IAmm.Dir.ADD_TO_AMM : IAmm.Dir.REMOVE_FROM_AMM,
            oldPositionSize.abs(),
            _quoteAssetAmountLimit,
            _skipFluctuationCheck
        );

        clearPosition(_amm, _trader);
    }

    function swapInput(
        IAmm _amm,
        Side _side,
        Decimal.decimal memory _inputAmount,
        Decimal.decimal memory _minOutputAmount
    ) internal returns (SignedDecimal.signedDecimal memory) {
        IAmm.Dir dir = (_side == Side.BUY) ? IAmm.Dir.ADD_TO_AMM : IAmm.Dir.REMOVE_FROM_AMM;
        SignedDecimal.signedDecimal memory outputAmount = MixedDecimal.fromDecimal(
            _amm.swapInput(dir, _inputAmount, _minOutputAmount)
        );
        if (IAmm.Dir.REMOVE_FROM_AMM == dir) {
            return outputAmount.mulScalar(-1);
        }
        return outputAmount;
    }

    // ensure the caller already check the inputs
    function updateMargin(
        IAmm _amm,
        address _trader,
        SignedDecimal.signedDecimal memory _margin
    ) private returns (Decimal.decimal memory) {
        // update margin part in personal position, including funding payment, and get new margin
        Position memory position = adjustPositionForLiquidityChanged(_amm, _trader);
        (
            SignedDecimal.signedDecimal memory remainMargin,
            SignedDecimal.signedDecimal memory latestCumulativePremiumFraction,
            Decimal.decimal memory badDebt
        ) = calcRemainMarginWithFundingPayment(_amm, position, _margin);

        // update position
        require(!remainMargin.isNegative() && badDebt.toUint() == 0, "Margin is not enough");
        position.margin = remainMargin.abs();
        position.lastUpdatedCumulativePremiumFraction = latestCumulativePremiumFraction;
        setPosition(_amm, _trader, position);
        return position.margin;
    }

    function transferFee(
        address _from,
        IAmm _amm,
        Decimal.decimal memory _positionNotional
    ) internal returns (Decimal.decimal memory) {
        (Decimal.decimal memory toll, Decimal.decimal memory spread) = _amm.calcFee(_positionNotional);
        bool hasToll = toll.toUint() > 0;
        bool hasSpread = spread.toUint() > 0;
        if (!hasToll && !hasSpread) {
            return Decimal.zero();
        }

        IERC20 quoteAsset = _amm.quoteAsset();

        // transfer spread to insurance fund
        if (hasSpread) {
            address insuranceFundAddress = address(insuranceFund);
            _transferFrom(quoteAsset, _from, insuranceFundAddress, spread);
        }

        // transfer toll to feePool, it's `stakingReserve` for now.
        if (hasToll) {
            require(address(feePool) != address(0), "Invalid FeePool");
            _transferFrom(quoteAsset, _from, address(feePool), toll);
            feePool.notifyTokenAmount(quoteAsset, toll);
        }

        // fee = spread + toll
        return toll.addD(spread);
    }

    function withdraw(
        IERC20 _token,
        address _receiver,
        Decimal.decimal memory _amount
    ) internal {
        // if withdraw amount is larger than entire balance of vault
        // means this trader's profit comes from other under collateral position's future loss
        // and the balance of entire vault is not enough
        // need money from IInsuranceFund to pay first, and record this prepaidBadDebt
        // in this case, insurance fund loss must be zero
        Decimal.decimal memory totalTokenBalance = _balanceOf(_token, address(this));
        if (totalTokenBalance.toUint() < _amount.toUint()) {
            Decimal.decimal memory balanceShortage = _amount.subD(totalTokenBalance);
            prepaidBadDebt[address(_token)] = getPrepaidBadDebt(address(_token)).addD(balanceShortage);
            insuranceFund.withdraw(_token, balanceShortage);
        }

        _transfer(_token, _receiver, _amount);
    }

    function realizeBadDebt(IERC20 _token, Decimal.decimal memory _badDebt) internal {
        Decimal.decimal memory badDebtBalance = getPrepaidBadDebt(address(_token));
        if (badDebtBalance.toUint() > _badDebt.toUint()) {
            // no need to move extra tokens because vault already prepay bad debt, only need to update the numbers
            prepaidBadDebt[address(_token)] = badDebtBalance.subD(_badDebt);
        } else {
            // in order to realize all the bad debt vault need extra tokens from insuranceFund
            insuranceFund.withdraw(_token, _badDebt.subD(badDebtBalance));
            prepaidBadDebt[address(_token)] = Decimal.zero();
        }
    }

    function transferToInsuranceFund(IERC20 _token, Decimal.decimal memory _amount) internal {
        Decimal.decimal memory totalTokenBalance = _balanceOf(_token, address(this));
        Decimal.decimal memory tokenToInsuranceFund = totalTokenBalance.toUint() < _amount.toUint()
            ? totalTokenBalance
            : _amount;
        _transfer(_token, address(insuranceFund), tokenToInsuranceFund);
    }

    //
    // INTERNAL VIEW FUNCTIONS
    //

    function calcRemainMarginWithFundingPayment(
        IAmm _amm,
        Position memory _oldPosition,
        SignedDecimal.signedDecimal memory _marginDelta
    )
        private
        view
        returns (
            SignedDecimal.signedDecimal memory remainMargin,
            SignedDecimal.signedDecimal memory latestCumulativePremiumFraction,
            Decimal.decimal memory badDebt
        )
    {
        // calculate funding payment
        latestCumulativePremiumFraction = getLatestCumulativePremiumFraction(_amm);
        SignedDecimal.signedDecimal memory fundingPayment = _oldPosition.size.toInt() == 0
            ? SignedDecimal.zero()
            : latestCumulativePremiumFraction
                .subD(_oldPosition.lastUpdatedCumulativePremiumFraction)
                .mulD(_oldPosition.size)
                .mulScalar(-1);

        // calculate remain margin
        remainMargin = fundingPayment.addD(_oldPosition.margin).addD(_marginDelta);
        if (remainMargin.toInt() < 0) {
            badDebt = remainMargin.abs();
            remainMargin = SignedDecimal.zero();
        }
    }

    function getUnadjustedPosition(IAmm _amm, address _trader) internal view returns (Position memory position) {
        position = ammMap[address(_amm)].positionMap[_trader];
        // set position.liquidityBasis to current amm.cumulativePositionMultiplier if its a new position
        if (position.size.toUint() == 0) {
            position.liquidityBasis = _amm.getCumulativePositionMultiplier();
        }
    }

    // prettier-ignore
    function _msgSender() internal override(BaseRelayRecipient, ContextUpgradeSafe) view returns (address payable) {
        return super._msgSender();
    }

    //
    // REQUIRE FUNCTIONS
    //
    function requireAmm(IAmm _amm, bool _open) private view {
        require(insuranceFund.isExistedAmm(_amm), "amm not found");
        require(_open == _amm.open(), _open ? "amm was closed" : "amm is open");
    }

    function requireEnoughMarginRatio(SignedDecimal.signedDecimal memory _marginRatio) private view {
        require(_marginRatio.subD(initMarginRatio).toInt() > 0, "marginRatio not enough");
    }

    function requireNonZeroInput(Decimal.decimal memory _decimal) private pure {
        require(_decimal.toUint() != 0, "input is 0");
    }

    function requirePositionSize(SignedDecimal.signedDecimal memory _size) private pure {
        require(_size.toInt() != 0, "positionSize is 0");
    }

    function requireNotRestrictionMode(IAmm _amm) private view {
        uint256 currentBlock = _blockNumber();
        if (currentBlock == ammMap[address(_amm)].lastRestrictionBlock) {
            require(getUnadjustedPosition(_amm, _msgSender()).blockNumber != currentBlock, "only one action allowed");
        }
    }
}