// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FeeSplits as F} from "../libraries/FeeSplits.sol";
import {IFeeSink} from "../interfaces/IProtocol.sol";

/// @title StrayFeeHook
/// @notice Takes §8's trading fee, in ETH, on every swap through the pool: 3.00 % buying,
///         4.00 % selling, plus a launch surcharge: both sides open at 30 % and fall one
///         percentage point a minute until they reach the permanent rate, after 27 minutes.
///
/// @dev ## Why a hook and not a router
///
///      The fee has to be ETH -- §8 routes it to holders and the stash, both of which are
///      ETH-only, and §12.1 spends a page explaining why the protocol does not swap. A
///      transfer tax in the ERC-20 can only ever withhold $STRAY, so the fee has to be
///      taken where ETH changes hands: inside the swap.
///
///      A router could do that too, but only for people who use it. Anyone trading
///      straight against the pool would pay nothing, and aggregators would route around it
///      by default. A hook is charged by the PoolManager itself, so it applies to everyone
///      who touches this pool.
///
///      The remaining gap, stated plainly: a hook protects THIS pool. Somebody could open
///      a second, hookless pool for the same token and trade there for free. The defence is
///      economic rather than technical -- the launch ladder and the reserve are the only
///      meaningful liquidity, and both live here, so a competing pool would have no depth
///      and whoever funded one would be subsidising other people's trades.
///
///      ## Which side the fee comes from
///
///      Native ETH sorts to `currency0`, so the pool is (ETH, $STRAY) and the fee is always
///      taken from currency0. Where that sits in the swap depends on the direction:
///
///        - buying $STRAY with ETH: the ETH is the input, and the input is the specified
///          amount, so `beforeSwap` skims it before the swap sees it;
///        - selling $STRAY for ETH: the ETH is the output, which is the unspecified
///          amount, so `afterSwap` skims it from the proceeds.
///
///      Either way the trader pays a percentage of the ETH leg and the pool itself is
///      untouched.
///
///      ## Nothing is pushed out of the swap path
///
///      An earlier version handed each fee straight to the RevenueRouter inside the swap.
///      That call reached the router, which called the oracle, which reverts unless the
///      caller is its registered reporter. So one misconfiguration anywhere down that chain
///      would have reverted EVERY swap in the pool, permanently, with no way to change the
///      sink because it is immutable here.
///
///      Volume reporting is telemetry. Telemetry must not be able to stop trading. So the
///      swap path now does exactly two things -- take the fee, add it to a counter -- and
///      `flush()` moves it on. `flush` is permissionless and has no deadline; if the router
///      is ever unable to accept, the ether simply stays here until it can.
///
///      ## The launch surcharge
///
///      For the first minutes the fee carries a surcharge on top of the permanent rate. Both
///      sides open at 30 % and fall one percentage point a minute, second by second: the
///      sell side meets its 4.00 % at 26 minutes, the buy side its 3.00 % at 27, and the cut-off
///      at 27 minutes is therefore a formality. At the ten-minute mark both sides pay 20 %.
///
///      It is not anti-snipe protection and is not sold as such. On this chain ordering is
///      first-come-first-served with no public mempool and no priority auction, so the
///      first buyer is decided by network latency and no fee schedule changes that. What a
///      surcharge changes is what that buyer pays. The trade-off of a long window, accepted
///      by the owner (2026-10-03): bots can simply wait it out, so it mostly charges the
///      people who show up early, and what it collects goes to liquidity first (§8).
///
///      The curve is strictly decreasing, which is a hard requirement rather than an
///      aesthetic one: aggregator safety classifiers reject hooks whose settlement can come
///      out worse than the quote, and a decreasing curve can only ever settle better.
///
///      ## The one address that pays nothing
///
///      §10's buyback buys $STRAY in this pool with fee ETH. Charged normally it would pay
///      the fee to a router that hands most of it straight back, so part of every buyback
///      would be recycled instead of spent on tokens.
///
///      So exactly one address is exempt: BUYBACK, set in this constructor, with no setter,
///      no list and no governance path. Three things make that safe rather than a hole:
///
///        1. The exempt address is an immutable contract whose only two outputs are a burn
///           and a deposit into the reserve. Its `execute` is permissionless, but the caller
///           receives nothing -- it cannot be used as a fee-free route for anybody's trade.
///        2. The exemption is baked into this hook's creation code, and therefore into the
///           mined hook address. It cannot be added later, to anyone, by anyone.
///        3. There is no second entry. A maintainable allowlist would make §8's rates
///           negotiable, and §8 marks those numbers final.
///
///      Only the buy leg is exempt, because the buyback only ever buys. It holds no $STRAY
///      between transactions and has no code path that sells, so an exemption on the sell
///      leg would be a rule for a case that cannot occur.
///
///      Deployment consequence, stated here because it constrains the order: the buyback's
///      address is a constructor argument, so it is part of the address this hook must be
///      mined to. The buyback has to be final before the hook is mined, and the hook before
///      the pool is created.
///
///      ## Binding, and why it takes four checks rather than one
///
///      `afterInitialize` latches the pool this hook charges for. The previous version
///      checked only that currency0 was native ETH -- which anybody could satisfy. For the
///      price of one transaction, a stranger could have initialised a junk (ETH, THEIR_TOKEN)
///      pool against this hook's address, latched `poolBound` to it, and made the real pool
///      impossible to create: every later `initialize` would revert with AlreadyBound, and
///      every swap in the junk pool would be charged for.
///
///      The blast radius was the whole stack, because RevenueRouter's `lockFeeHook` is a
///      one-shot latch and V4PoolOracle's POOL_ID is immutable -- so a re-mined hook would
///      have forced redeploying both. The fix is to pin every field of the expected key that
///      is knowable in advance. The PoolId itself cannot be a constructor argument: it
///      depends on the hook address, which depends on the constructor arguments.
///
///      ## Exact-output swaps are refused
///
///      In an exact-output swap the roles above are reversed, and the delta conventions
///      with them. Handling that correctly is a second set of sign rules, and a sign error
///      here does not fail loudly -- it either takes nothing or takes from the wrong party.
///      Reverting is the safe answer: a refused swap costs somebody a retry, a wrong one
///      costs money. The cost is real and is stated in the risk register: routers quoting
///      exact-output through this pool will fail, and fixing it later needs a new address.
contract StrayFeeHook is IHooks {
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable POOL_MANAGER;

    /// @notice Where the fee goes. Immutable: this contract sits in the path of every
    ///         trade, and a redirectable destination there would be a standing risk.
    address public immutable FEE_SINK;

    /// @notice The single address that buys here without paying the fee: §10's buyback.
    /// @dev Immutable, no setter, no list. See the note above for why one exemption is
    ///      safe and why a second would not be. Publicly readable on purpose -- anyone
    ///      auditing this contract should find it without having to look for it.
    address public immutable BUYBACK;

    // ---------------------------------------------------------------------
    // The pool this hook is for, pinned as far as it can be before mining
    // ---------------------------------------------------------------------

    /// @notice The $STRAY side of the expected pool. currency0 must be native ETH.
    address public immutable EXPECTED_CURRENCY1;
    /// @notice The expected `fee` field of the pool key.
    uint24 public immutable EXPECTED_FEE;
    /// @notice The expected tick spacing.
    int24 public immutable EXPECTED_TICK_SPACING;

    /// @notice The one pool this hook charges for, latched on its initialisation.
    PoolId public poolId;
    bool public poolBound;

    /// @notice When the pool was created. The launch curve is measured from here.
    /// @dev Captured on chain rather than passed in, so a delayed launch cannot burn the
    ///      window and an early one cannot extend it.
    uint64 public launchedAt;

    // ---------------------------------------------------------------------
    // §8, and constants
    // ---------------------------------------------------------------------

    /// @notice The permanent rates: 3.00 % buying, 4.00 % selling.
    uint24 public constant BUY_FEE_BPS = F.BUY_FEE_BPS;
    uint24 public constant SELL_FEE_BPS = F.SELL_FEE_BPS;

    /// @notice The total rate at the instant the pool opens, the same on both sides: 30 %.
    /// @dev Owner's decision of 2026-10-03: one curve for buying and selling, nothing more
    ///      complicated, starting at 30 %. Known and accepted: for its first five minutes the
    ///      sell side sits above the 2,500 bp line some token scanners flag as a high sell tax.
    uint24 public constant LAUNCH_START_BPS = 3000;

    /// @notice How fast the rate falls: one percentage point a minute, second by second.
    uint24 public constant LAUNCH_DECAY_BPS_PER_MINUTE = 100;

    /// @notice When the surcharge is over on both sides: 27 minutes.
    /// @dev The buy side reaches its permanent 3.00 % at exactly 27 minutes, the sell side
    ///      its 4.00 % at 26. From there the curve sits on the permanent rate, so crossing this
    ///      line changes the rate by exactly nothing -- a step here would be a free, riskless
    ///      target, and a step UP anywhere would lose the aggregator routing the curve keeps.
    uint64 public constant LAUNCH_WINDOW =
        uint64((LAUNCH_START_BPS - F.BUY_FEE_BPS) / LAUNCH_DECAY_BPS_PER_MINUTE) * 1 minutes;

    // ---------------------------------------------------------------------
    // What has been taken and not yet handed on
    // ---------------------------------------------------------------------

    /// @notice Fee ether held here, kept apart by direction for §8's two tables.
    ///
    /// @dev These hold the PERMANENT rate only -- 3.00 % of a buy, 4.00 % of a sell. The
    ///      launch surcharge is kept separately below, and the reason is the whole §8
    ///      invariant.
    ///
    ///      The router splits what arrives by dividing it against the permanent rate: a leg
    ///      is `fee x legBps / feeBps`, which recovers the volume and gives each destination
    ///      its basis points OF VOLUME. That identity only holds if what arrives really was
    ///      charged at the permanent rate. Hand it a fee charged at 30 % and every leg comes
    ///      out inflated by the ratio -- ops, which §8 fixes at 0.20 % of volume and calls
    ///      the one position that never moves, would take 26x its share for the first four
    ///      minutes of the pool's life.
    ///
    ///      So the surcharge never enters that arithmetic. It is a separate stream with a
    ///      single destination.
    uint256 public pendingBuyWei;
    uint256 public pendingSellWei;

    /// @notice The launch surcharge, above the permanent rate, awaiting a flush.
    ///
    /// @dev WHERE it goes is decided in RevenueRouter, which is upgradeable -- today
    ///      liquidity 70, holder 10, stash 10, race 10 (FeeSplits.SURCHARGE_*). WHETHER it is kept
    ///      apart from the §8 split is decided here and is permanent, and it has to be: the
    ///      router can only split a stream it can tell apart, and after this contract is
    ///      mined nothing can teach it to tell them apart again.
    uint256 public pendingSurchargeWei;

    /// @notice Gross ETH volume seen but not yet reported to the oracle.
    uint256 public pendingVolumeWei;

    /// @notice Lifetime totals, for anyone reading this contract rather than its events.
    uint256 public lifetimeBuyFeeWei;
    uint256 public lifetimeSellFeeWei;
    uint256 public lifetimeSurchargeWei;
    uint256 public lifetimeVolumeWei;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice What this hook knows about a swap that nothing else records.
    ///
    /// @dev Written here, read by consumers -- never pushed. A hook is in the path of every
    ///      trade and can never be replaced, so it must not depend on any other contract
    ///      accepting a call.
    ///
    ///      The fields are deliberately the complement of v4's own `Swap` event rather than
    ///      a superset of it. The manager already emits, for the same swap in the same
    ///      transaction: both token amounts, `sqrtPriceX96`, the liquidity and the tick. An
    ///      indexer joins on the pool id and gets all of that for free, so re-reading slot0
    ///      here would cost gas on every trade to publish a number that is already in the
    ///      receipt.
    ///
    ///      What is NOT anywhere else is this: which side the protocol charged, the ETH leg
    ///      it charged against, the fee it actually took, and the rate that produced it.
    ///      The rate matters because the launch curve makes it a function of the block
    ///      timestamp -- it cannot be reconstructed from the constants alone.
    event FeeTaken(
        PoolId indexed id, address indexed sender, bool buying, uint256 ethGross, uint256 feeEth, uint24 rateBps
    );

    event PoolBound(PoolId id, uint64 launchedAt);
    event Flushed(uint256 buyWei, uint256 sellWei, uint256 surchargeWei, uint256 volumeWei);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotPoolManager();
    error WrongPool();
    error ExactOutputNotSupported();
    error PriceLimitNotSupported();
    error NativeCurrencyExpected();
    error WrongToken();
    error WrongFee();
    error WrongTickSpacing();
    error AlreadyBound();
    error ZeroAddress();
    error NothingToFlush();

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        _;
    }

    constructor(
        address poolManager,
        address feeSink,
        address buyback,
        address expectedCurrency1,
        uint24 expectedFee,
        int24 expectedTickSpacing
    ) {
        if (
            poolManager == address(0) || feeSink == address(0) || buyback == address(0)
                || expectedCurrency1 == address(0)
        ) revert ZeroAddress();

        POOL_MANAGER = IPoolManager(poolManager);
        FEE_SINK = feeSink;
        BUYBACK = buyback;
        EXPECTED_CURRENCY1 = expectedCurrency1;
        EXPECTED_FEE = expectedFee;
        EXPECTED_TICK_SPACING = expectedTickSpacing;

        // The PoolManager reads the permissions from the low bits of this address, so a
        // hook only works if it was deployed to a mined one. Checking here turns a silent
        // misdeployment into a failed deployment.
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    /// @notice The address bits a deployment has to match.
    function requiredFlags() public pure returns (uint160) {
        return Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    }

    // =====================================================================
    // The rate in force right now
    // =====================================================================

    /// @notice What a swap in this direction is charged at this instant, in basis points.
    ///
    /// @dev `max(permanent, 30 % - 1 % x elapsed minutes)`, computed per second in integers.
    ///
    ///      The decay is `elapsed x 100 / 60` basis points: 1.67 a second, so the rate falls
    ///      by one or two basis points every second and never stands still while it is above
    ///      the permanent rate. The truncation is the protocol's way (§0): it rounds the
    ///      decay down, never the rate.
    ///
    ///      What matters most is that the curve is strictly decreasing at every second until
    ///      it meets the permanent rate, and flat after. A quote can then never settle worse
    ///      than it was given -- which is the thing aggregator safety classifiers actually
    ///      test, and losing their routing would cost more than this surcharge can collect.
    function currentFeeBps(bool buying) public view returns (uint24) {
        uint24 permanent = buying ? BUY_FEE_BPS : SELL_FEE_BPS;
        if (!poolBound) return permanent;

        uint64 elapsed = uint64(block.timestamp) - launchedAt;
        if (elapsed >= LAUNCH_WINDOW) return permanent;

        uint256 decay = (uint256(elapsed) * LAUNCH_DECAY_BPS_PER_MINUTE) / 1 minutes;
        if (decay >= LAUNCH_START_BPS - permanent) return permanent;
        return uint24(LAUNCH_START_BPS - decay);
    }

    /// @notice Seconds until the launch surcharge is gone, zero once it is.
    function launchWindowRemaining() external view returns (uint64) {
        if (!poolBound) return LAUNCH_WINDOW;
        uint64 elapsed = uint64(block.timestamp) - launchedAt;
        return elapsed >= LAUNCH_WINDOW ? 0 : LAUNCH_WINDOW - elapsed;
    }

    // =====================================================================
    // Binding
    // =====================================================================

    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (poolBound) revert AlreadyBound();

        // Every field of the key that can be known before this hook's address is mined is
        // checked. Without these a stranger bricks the pool for the price of one
        // transaction; see the note at the top of the contract.
        if (!key.currency0.isAddressZero()) revert NativeCurrencyExpected();
        if (Currency.unwrap(key.currency1) != EXPECTED_CURRENCY1) revert WrongToken();
        if (key.fee != EXPECTED_FEE) revert WrongFee();
        if (key.tickSpacing != EXPECTED_TICK_SPACING) revert WrongTickSpacing();

        poolId = key.toId();
        poolBound = true;
        launchedAt = uint64(block.timestamp);

        emit PoolBound(poolId, launchedAt);
        return IHooks.afterInitialize.selector;
    }

    // =====================================================================
    // Buying: the ETH is the input, and the input is what was specified
    // =====================================================================

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        _requireOurPool(key);
        // amountSpecified < 0 is exact input. See the note on exact output above.
        if (params.amountSpecified >= 0) revert ExactOutputNotSupported();

        // The protocol buying back its own token. `sender` is whoever called
        // PoolManager.swap, and the buyback calls it from inside its own unlock, so this
        // is the buyback itself and never somebody routing through it.
        if (sender == BUYBACK) {
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        if (!params.zeroForOne) {
            // Selling $STRAY: the ETH is on the way out, so afterSwap handles it.
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        // A buy is charged BEFORE the swap, on the amount offered, because that is the only
        // moment the ETH leg can be taxed: on a zeroForOne exact-input swap the unspecified
        // currency is $STRAY, so afterSwap could only ever take its cut in the wrong token.
        //
        // That is sound exactly when the pool consumes the whole offer. A price limit breaks
        // it: v4 stops the swap the moment the limit is reached and refunds the rest, already
        // taxed. Measured against the live manager on chain 4663 -- 10 ETH offered, 0.15 ETH
        // actually swapped, 0.30 ETH taken as the fee. Twice the trade. Inside the launch
        // window the same shape charges 8 ETH on a swap that moves a single wei.
        //
        // So a price limit is refused, for the same reason exact output is: the hook cannot
        // price what it cannot see. The cost is measured too, and it is small. Uniswap's own
        // V4Router -- which the Universal Router routes through -- never exposes a limit and
        // always passes MIN_SQRT_PRICE + 1 here. What this refuses is a router that splits a
        // buy across pools with a genuine limit; it goes into the risk register next to exact
        // output. The sell side needs nothing: it charges from the realized delta.
        if (params.sqrtPriceLimitX96 != TickMath.MIN_SQRT_PRICE + 1) revert PriceLimitNotSupported();

        uint256 ethIn = uint256(-params.amountSpecified);
        uint24 rate = currentFeeBps(true);
        uint256 fee = (ethIn * rate) / 10_000;
        if (fee == 0) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);

        // The permanent share and the launch surcharge are booked apart. `rate` is never
        // below BUY_FEE_BPS, so the subtraction cannot go negative.
        uint256 base = (ethIn * BUY_FEE_BPS) / 10_000;
        uint256 surcharge = fee - base;

        // A positive delta on the specified currency means the hook is owed that much: the
        // swap proceeds on `ethIn - fee`, and the hook takes the difference.
        POOL_MANAGER.take(key.currency0, address(this), fee);

        pendingBuyWei += base;
        pendingSurchargeWei += surcharge;
        pendingVolumeWei += ethIn;
        lifetimeBuyFeeWei += base;
        lifetimeSurchargeWei += surcharge;
        lifetimeVolumeWei += ethIn;

        emit FeeTaken(poolId, sender, true, ethIn, fee, rate);

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    // =====================================================================
    // Selling: the ETH is the output, which is the unspecified amount
    // =====================================================================

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _requireOurPool(key);
        if (params.zeroForOne) return (IHooks.afterSwap.selector, 0); // handled in beforeSwap

        // amount0 is what the swapper receives in currency0, so it is positive here.
        int128 ethOut = delta.amount0();
        if (ethOut <= 0) return (IHooks.afterSwap.selector, 0);

        uint256 gross = uint256(uint128(ethOut));
        uint24 rate = currentFeeBps(false);
        uint256 fee = (gross * rate) / 10_000;
        if (fee == 0) return (IHooks.afterSwap.selector, 0);

        uint256 base = (gross * SELL_FEE_BPS) / 10_000;
        uint256 surcharge = fee - base;

        POOL_MANAGER.take(key.currency0, address(this), fee);

        pendingSellWei += base;
        pendingSurchargeWei += surcharge;
        pendingVolumeWei += gross;
        lifetimeSellFeeWei += base;
        lifetimeSurchargeWei += surcharge;
        lifetimeVolumeWei += gross;

        emit FeeTaken(poolId, sender, false, gross, fee, rate);

        // A positive return reduces what the swapper walks away with by exactly the fee.
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    // =====================================================================
    // Handing it on
    // =====================================================================

    /// @notice Send everything taken so far to the revenue router. Anyone may call.
    ///
    /// @dev Deliberately outside the swap path. If the router or anything behind it reverts,
    ///      this call reverts and the ether stays here, untouched and still owed -- rather
    ///      than a swap reverting. There is no deadline and no privileged caller, so the
    ///      only way for this to stop working permanently is for the router to stop
    ///      accepting, and the router is upgradeable.
    function flush() external returns (uint256 buyWei, uint256 sellWei, uint256 surchargeWei) {
        buyWei = pendingBuyWei;
        sellWei = pendingSellWei;
        surchargeWei = pendingSurchargeWei;
        uint256 volume = pendingVolumeWei;
        if (buyWei == 0 && sellWei == 0 && surchargeWei == 0) revert NothingToFlush();

        pendingBuyWei = 0;
        pendingSellWei = 0;
        pendingSurchargeWei = 0;
        pendingVolumeWei = 0;

        IFeeSink(FEE_SINK).receiveTradingFee{value: buyWei + sellWei + surchargeWei}(
            buyWei, sellWei, surchargeWei, volume
        );
        emit Flushed(buyWei, sellWei, surchargeWei, volume);
    }

    // =====================================================================
    // Internals
    // =====================================================================

    function _requireOurPool(PoolKey calldata key) internal view {
        if (!poolBound || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
    }

    // =====================================================================
    // The rest of IHooks: declined, explicitly
    // =====================================================================
    //
    // The PoolManager never calls these, because the permission bits in this contract's
    // address are not set for them. They revert rather than returning a selector so that a
    // misdeployment to an address with the wrong bits fails loudly instead of quietly
    // letting operations through unhooked.

    error HookNotImplemented();

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @dev Receives the ETH it takes from the PoolManager, on its way to the router.
    receive() external payable {}
}
