// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IProtocol
/// @notice The doors the protocol's own contracts call on each other.
///
/// @dev These used to be declared inside whichever file happened to make the call --
///      nine little interfaces across six files, several of them the same shape under two
///      names. That works, and it typechecks, but only by coincidence: the caller declares
///      what it believes the callee looks like and nothing ever compares the two. A callee
///      whose signature drifts still compiles on both sides, and the mismatch surfaces
///      only at runtime, as a call that reverts with no data.
///
///      Collected here and implemented by declaration on the callee side, so the compiler
///      checks the pairing instead of the integration test. Named for the role rather than
///      for the contract, because the whole point of an interface here is that the
///      implementation behind it is replaceable -- the entropy provider explicitly so
///      (§12), and the pots and the vault through their proxies.
interface ICoreDeposits {
    function depositHolderRewards() external payable;
    function depositStash() external payable;
}

/// @notice The reserve vault's three inflow doors.
/// @dev The two ETH doors are deliberately separate: `depositEth` is reserve capital that
///      the cap and the overflow router apply to, `depositEthForLiquidity` is the §8
///      liquidity leg, which is earmarked and is not the reserve's own money.
interface IVaultDeposits {
    function depositEth() external payable;
    function depositEthForLiquidity() external payable;
    function depositStray(uint256 amount) external;
}

/// @notice Today's race pot.
interface IRacePot {
    function fundEth() external payable;
    function fundStray(uint256 amount) external;
    function todaysPotUsd8() external view returns (uint256);
}

/// @notice Today's jackpot pot.
interface IJackpotPot {
    function fundEth() external payable;
    function fundStray(uint256 amount) external;
}

/// @notice Where the §8 buyback leg is parked until the executor runs.
interface IBuyback {
    function fund() external payable;
}

/// @notice Where the fee hook hands what it took. Three streams, because §8 splits a buy and
///         a sell by different tables and the launch surcharge by neither -- splitting a
///         surcharge-inflated fee against the permanent rate would hand every destination a
///         multiple of its share. The gross ETH volume behind all of it comes along.
/// @notice WETH9, as far as the router unwraps royalties paid in it.
interface IWETH {
    function balanceOf(address owner) external view returns (uint256);
    function withdraw(uint256 wad) external;
}

interface IFeeSink {
    function receiveTradingFee(uint256 buyWei, uint256 sellWei, uint256 surchargeWei, uint256 ethVolume)
        external
        payable;
}

/// @notice The randomness adapter, from a consumer's side.
interface IEntropyRequester {
    function request(bytes32 userSeed, bool allowFallback) external payable returns (uint64);
    function fee() external view returns (uint256);
}

/// @notice The one-directional door into pool liquidity.
interface ILiquidityDeployer {
    function deploy(uint256 strayAmount) external payable;
}
