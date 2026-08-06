// SPDX-License-Identifier: GPL-2.0-or-later
methods {
    function extSloads(bytes32[]) external returns bytes32[] => NONDET DELETE;

    function _.borrowRate(MorphoHarness.MarketParams marketParams, MorphoHarness.Market) external => summaryBorrowRate() expect uint256;
    function _.on(bytes32, uint8, bytes) external => summaryControllerHook() expect void;

    function hookInProgress() external returns bool envfree;
}

persistent ghost bool delegateCall;
persistent ghost bool callIsBorrowRate;
persistent ghost bool callIsControllerHook;
// True when storage has been accessed with either a SSTORE or a SLOAD.
persistent ghost bool hasAccessedStorage;
// True when a CALL has been done after storage has been accessed.
persistent ghost bool hasCallAfterAccessingStorage;
// True when storage has been accessed, after which an external call is made, followed by accessing storage again.
persistent ghost bool hasReentrancyUnsafeCall;

function summaryBorrowRate() returns uint256 {
    uint256 result;
    callIsBorrowRate = true;
    return result;
}

function summaryControllerHook() {
    assert hookInProgress();
    callIsControllerHook = true;
}

hook ALL_SSTORE(uint loc, uint v) {
    hasAccessedStorage = true;
    hasReentrancyUnsafeCall = hasCallAfterAccessingStorage;
}

hook ALL_SLOAD(uint loc) uint v {
    hasAccessedStorage = true;
    hasReentrancyUnsafeCall = hasCallAfterAccessingStorage;
}

hook CALL(uint g, address addr, uint value, uint argsOffset, uint argsLength, uint retOffset, uint retLength) uint rc {
    if (callIsBorrowRate || callIsControllerHook) {
        // IRM calls are trusted by the inherited model. Controller calls are protected by the
        // transient hook lock and are checked separately below.
        callIsBorrowRate = false;
        callIsControllerHook = false;
    } else {
        hasCallAfterAccessingStorage = hasAccessedStorage;
    }
}

hook DELEGATECALL(uint g, address addr, uint argsOffset, uint argsLength, uint retOffset, uint retLength) uint rc {
    delegateCall = true;
}

// Check that no function performs an unprotected external call between storage accesses.
rule noUnprotectedExternalCall(method f, env e, calldataarg data) {
    // Set up the initial state.
    require !callIsBorrowRate && !callIsControllerHook;
    require !hasAccessedStorage && !hasCallAfterAccessingStorage && !hasReentrancyUnsafeCall;
    f(e, data);
    assert !hasReentrancyUnsafeCall;
}

// Every successfully completed hooked action releases the transient lock.
rule hookedActionReleasesLock(method f, env e, calldataarg data) filtered {
    f ->
        f.selector == sig:supply(MorphoHarness.MarketParams, uint256, uint256, address, bytes).selector
        || f.selector == sig:withdraw(MorphoHarness.MarketParams, uint256, uint256, address, address).selector
        || f.selector == sig:borrow(MorphoHarness.MarketParams, uint256, uint256, address, address).selector
        || f.selector == sig:repay(MorphoHarness.MarketParams, uint256, uint256, address, bytes).selector
        || f.selector == sig:supplyCollateral(MorphoHarness.MarketParams, uint256, address, bytes).selector
        || f.selector == sig:withdrawCollateral(MorphoHarness.MarketParams, uint256, address, address).selector
        || f.selector == sig:liquidate(MorphoHarness.MarketParams, address, uint256, uint256, bytes).selector
        || f.selector == sig:accrueInterest(MorphoHarness.MarketParams).selector
        || f.selector == sig:settle(MorphoHarness.MarketParams, uint256, address, address, address).selector
} {
    require !hookInProgress();
    f(e, data);
    assert !hookInProgress();
}

// Check that LidoLend never executes a delegatecall.
rule noDelegateCalls(method f, env e, calldataarg data) {
    // Set up the initial state.
    require !delegateCall;
    f(e, data);
    assert !delegateCall;
}
