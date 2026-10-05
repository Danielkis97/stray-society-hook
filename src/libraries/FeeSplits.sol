// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/// @title FeeSplits
/// @notice Every locked quota in the protocol, as compile-time constants.
///
/// @dev §8 says "Status: final" about the trading fee, and the blueprint appendix
///      recomputes all of these. Final numbers belong in a library the immutable
///      contracts link against, not in storage behind a proxy: an upgrade may change how
///      much flows, never how a given inflow is divided.
///
///      Everything is expressed in basis points OF THE INFLOW BEING SPLIT, not of the
///      underlying volume -- so a royalty row sums to 10_000 and means "share of the
///      royalty". The one exception is §8's trading split, which is in basis points of
///      VOLUME, for the reason given at that function.
library FeeSplits {
    uint16 internal constant BPS = 10_000;

    // =====================================================================
    // §8 · Token trading fee: 3.00 % buying, 4.00 % selling, four depth states
    // =====================================================================

    /// @notice The fee on a buy and on a sell, in basis points of the ETH leg.
    ///
    /// @dev Asymmetric on purpose. The sell side keeps the locked 4.00 % table unchanged;
    ///      the buy side is 3.00 %, and the missing percentage point comes out of the
    ///      buyback first, then out of holder and stash together. Liquidity, race and ops
    ///      are not touched on either side.
    ///
    ///      The consequence is known and accepted: the often-quoted -12.5 % of revenue only
    ///      holds when buy and sell volume are equal. At launch, buying dominates, so the
    ///      real shortfall is nearer 20-25 %. That is the price of charging buyers less.
    uint16 internal constant BUY_FEE_BPS = 300;
    uint16 internal constant SELL_FEE_BPS = 400;

    enum DepthState {
        BELOW_30K, //  < 30k  depth
        MID_30_60K, //  30k .. 60k
        MID_60_100K, //  60k .. 100k
        FULL_100K //  >= 100k
    }

    /// @notice Both §8 tables, in basis points OF THE VOLUME -- not of the fee.
    ///
    /// @dev This is the one place in the library that does not follow the house convention
    ///      of "basis points of the inflow being split", and the reason is worth stating.
    ///
    ///      Expressed as a share of the fee, ops is 500 bps of a 4.00 % fee on the sell side
    ///      and 667 bps of a 3.00 % fee on the buy side -- two different numbers that both
    ///      have to mean exactly 0.20 % of volume, and 667/10_000 x 300 does not. Expressed
    ///      as basis points of volume, ops is the integer 20 on every row of both tables,
    ///      and it is 0.20 % by construction rather than by rounding.
    ///
    ///      The caller therefore multiplies by volume, not by the fee it collected. The
    ///      residual rule below keeps that exact: the holder leg is never read from the
    ///      table, it is whatever is left after the other five are taken, so the six legs
    ///      always add up to the wei that actually arrived.
    ///
    ///        BUY -- 3.00 %      holder   lp   stash race  buyback  ops     sum
    ///          < 30k             1.50   0.80  0.40  0.10   0.00    0.20  = 3.00
    ///          30-60k            1.60   0.60  0.45  0.15   0.00    0.20  = 3.00
    ///          60-100k           1.75   0.30  0.55  0.20   0.00    0.20  = 3.00
    ///          >= 100k           1.85   0.05  0.65  0.25   0.00    0.20  = 3.00
    ///
    ///        SELL -- 4.00 %     holder   lp   stash race  buyback  ops     sum
    ///          < 30k             2.20   0.80  0.60  0.10   0.10    0.20  = 4.00
    ///          30-60k            2.30   0.60  0.65  0.15   0.10    0.20  = 4.00
    ///          60-100k           2.40   0.30  0.75  0.20   0.15    0.20  = 4.00
    ///          >= 100k           2.45   0.05  0.85  0.25   0.20    0.20  = 4.00
    ///
    ///      The buy side pays no buyback leg at all. §10's buyback buys $STRAY with fee ETH,
    ///      and funding it out of a buy is the protocol taking ether from somebody who is
    ///      already buying in order to buy on its own account a moment later. The sell side
    ///      is where that leg belongs, and it is the side that kept it.
    ///
    /// @return holder the residual leg, returned for reference only -- callers must compute
    ///         it as the remainder so no wei is stranded by integer division (§6a).
    function tradingSplit(DepthState s, bool buying)
        internal
        pure
        returns (uint16 holder, uint16 liquidity, uint16 stash, uint16 race, uint16 buyback, uint16 ops)
    {
        if (buying) {
            if (s == DepthState.BELOW_30K) return (150, 80, 40, 10, 0, 20);
            if (s == DepthState.MID_30_60K) return (160, 60, 45, 15, 0, 20);
            if (s == DepthState.MID_60_100K) return (175, 30, 55, 20, 0, 20);
            return (185, 5, 65, 25, 0, 20); // FULL_100K
        }
        if (s == DepthState.BELOW_30K) return (220, 80, 60, 10, 10, 20);
        if (s == DepthState.MID_30_60K) return (230, 60, 65, 15, 10, 20);
        if (s == DepthState.MID_60_100K) return (240, 30, 75, 20, 15, 20);
        return (245, 5, 85, 25, 20, 20); // FULL_100K
    }

    /// @notice The fee rate that applies to a given direction.
    function feeBps(bool buying) internal pure returns (uint16) {
        return buying ? BUY_FEE_BPS : SELL_FEE_BPS;
    }

    /// @notice The launch surcharge -- everything a trade pays above the permanent 3.00 % /
    ///         4.00 % during the opening minutes -- in basis points of the surcharge itself.
    ///
    /// @dev Liquidity 70 · Holder 10 · Stash 10 · Race 10 (owner's decision of 2026-10-03):
    ///      most of the opening toll goes straight into the pool's depth, through the
    ///      reserve's liquidity budget, and nothing of it to ops. Neither §8 table describes
    ///      this money, so it does not pass through them: the router splits it here, after
    ///      the §8 split and apart from it. Holder and Stash shares wait in their pots until
    ///      NFTs are active, as every pre-launch inflow does.
    ///
    ///      Holder takes the rounding remainder, as it does in §8, so the four legs always
    ///      add up to the wei that arrived.
    uint16 internal constant SURCHARGE_LIQUIDITY = 7000;
    uint16 internal constant SURCHARGE_HOLDER = 1000;
    uint16 internal constant SURCHARGE_STASH = 1000;
    uint16 internal constant SURCHARGE_RACE = 1000;

    // =====================================================================
    // §9 · NFT secondary fee, 10 %
    // =====================================================================

    /// @notice The royalty itself, in basis points of the sale price.
    uint16 internal constant NFT_ROYALTY_BPS = 1000;

    /// @dev Holder 40 · Stash 25 · Ops 15 · Race 5 · Jackpot 3 · Buyback 7 · Reserve 5.
    ///      §9: "Race sind direkt 5 %, Jackpot direkt 3 %" -- two separate allocations,
    ///      not a race share that a jackpot cut is taken out of.
    uint16 internal constant NFT_HOLDER = 4000;
    uint16 internal constant NFT_STASH = 2500;
    uint16 internal constant NFT_OPS = 1500;
    uint16 internal constant NFT_RACE = 500;
    uint16 internal constant NFT_JACKPOT = 300;
    uint16 internal constant NFT_BUYBACK = 700;
    uint16 internal constant NFT_RESERVE = 500;

    // =====================================================================
    // §10 · Buyback
    // =====================================================================

    /// @dev The buyback buys $STRAY with ETH, then splits the tokens.
    ///      "Der Buyback geht niemals in die Cage" -- the blueprint's name for the stash. A
    ///      floor denominated in the asset it is meant to support is not a floor.
    uint16 internal constant BUYBACK_BURN = 5000;
    uint16 internal constant BUYBACK_RESERVE = 5000;

    // =====================================================================
    // §10 · Reserve overflow router, two streams
    // =====================================================================

    /// @dev ETH stream: Stash 40 · Holder 40 · Race 15 · Jackpot 5 (owner's decision of
    ///      2026-10-02, the blueprint of 2026-09-30). No buyback share, because from ETH you
    ///      cannot burn without buying first -- "ETH -> Burn" does not exist.
    uint16 internal constant OVERFLOW_ETH_STASH = 4000;
    uint16 internal constant OVERFLOW_ETH_HOLDER = 4000;
    uint16 internal constant OVERFLOW_ETH_RACE = 1500;
    uint16 internal constant OVERFLOW_ETH_JACKPOT = 500;

    /// @dev $STRAY stream: Burn 50 · Jackpot 50. The only rule that matters is that none
    ///      of it returns to the reserve, or the loop never closes.
    uint16 internal constant OVERFLOW_STRAY_BURN = 5000;
    uint16 internal constant OVERFLOW_STRAY_JACKPOT = 5000;

    // =====================================================================
    // §10a · Reroll fee, paid in $STRAY
    // =====================================================================

    /// @dev Burn 40 · Race 20 · Jackpot 20 · Reserve 10 · Ops 10.
    ///      Holder rewards get 0 %: they are ETH, and any share would force a swap.
    uint16 internal constant REROLL_BURN = 4000;
    uint16 internal constant REROLL_RACE = 2000;
    uint16 internal constant REROLL_JACKPOT = 2000;
    uint16 internal constant REROLL_RESERVE = 1000;
    uint16 internal constant REROLL_OPS = 1000;

    /// @notice Reroll prices as parts per ten million of the initial supply (§10a).
    uint256 internal constant REROLL_TICKER_PPM = 90; // 0.0009 %  = 0.3 x L0->L1
    uint256 internal constant REROLL_COUNT_PPM = 144; // 0.00144 % = 1.6 x ticker

    /// @notice Escalation per roll, 1.10x, as a 1e18 fixed-point factor (§10a).
    /// @dev "Die Eskalation laeuft dauerhaft je NFT und wird nie zurueckgesetzt. Es gibt
    ///      keinen Deckel und keine Wartezeit." Two separate counters per tokenId, one for
    ///      ticker rolls and one for count rolls -- a shared counter would make every count
    ///      roll raise the price of all later ticker rolls, which is not what §10a says.
    uint256 internal constant REROLL_ESCALATION_WAD = 1.1e18;

    // =====================================================================
    // §12 · Daily jackpot
    // =====================================================================

    /// @dev Entry: Pot 60 · Early Entrant 20 · Burn 15 · Treasury 5.
    ///      "Kein Referral. Kein Stash-Anteil. Keine Next-Pot-Allokation. Und kein
    ///      Holder-Anteil." (§12.1)
    uint16 internal constant ENTRY_POT = 6000;
    uint16 internal constant ENTRY_EARLY = 2000;
    uint16 internal constant ENTRY_BURN = 1500;
    uint16 internal constant ENTRY_TREASURY = 500;

    /// @dev Payout, identical for the jackpot (§12) and the race (§11): 60 / 30 / 10.
    uint16 internal constant PRIZE_FIRST = 6000;
    uint16 internal constant PRIZE_SECOND = 3000;
    uint16 internal constant PRIZE_THIRD = 1000;

    /// @notice §12: hourly epochs, weight = stake x remaining epochs.
    uint8 internal constant EPOCHS_PER_DAY = 24;


    // =====================================================================
    // Helpers
    // =====================================================================

    /// @notice Split `amount` by `bps`, always rounding DOWN.
    /// @dev Rounding in favour of the protocol is the rule: whatever does not divide
    ///      evenly stays with the caller, which is the router, which carries it into the
    ///      next distribution rather than dropping it.
    function share(uint256 amount, uint16 bps) internal pure returns (uint256) {
        return (amount * bps) / BPS;
    }
}
