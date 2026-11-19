// SPDX-License-Identifier: GPL-2.0-or-later

using Util as Util;

methods {
    function extSloads(bytes32[]) external returns bytes32[] => NONDET DELETE;

    function Util.libMulDivUp(uint256, uint256, uint256) external returns uint256 envfree;
    function Util.libMulDivDown(uint256, uint256, uint256) external returns uint256 envfree;
    function Util.libId(MorphoHarness.MarketParams) external returns MorphoHarness.Id envfree;
    function Util.refId(MorphoHarness.MarketParams) external returns MorphoHarness.Id envfree;
    function Util.libMin(uint256 x, uint256 y) external returns uint256 envfree;
    function Util.libWDivUp(uint256, uint256) external returns uint256 envfree;
    function Util.libWDivDown(uint256, uint256) external returns uint256 envfree;
    function Util.libWMulDown(uint256, uint256) external returns uint256 envfree;
    function Util.libWTaylorCompounded(uint256, uint256) external returns uint256 envfree;
    function Util.toSharesDown(uint256, uint256, uint256) external returns uint256 envfree;
    function Util.toSharesUp(uint256, uint256, uint256) external returns uint256 envfree;
    function Util.toAssetsDown(uint256, uint256, uint256) external returns uint256 envfree;
    function Util.toAssetsUp(uint256, uint256, uint256) external returns uint256 envfree;
}

// Check the summary of MathLib.mulDivUp required by ExchangeRate.spec
rule checkSummaryMulDivUp(uint256 x, uint256 y, uint256 d) {
    uint256 result = Util.libMulDivUp(x, y, d);
    assert result * d >= x * y;
}

// Check the summary of MathLib.mulDivDown required by ExchangeRate.spec
rule checkSummaryMulDivDown(uint256 x, uint256 y, uint256 d) {
    uint256 result = Util.libMulDivDown(x, y, d);
    assert result * d <= x * y;
}

// Check the summary of MarketParamsLib.id required by Liveness.spec
rule checkSummaryId(MorphoHarness.MarketParams marketParams) {
    assert Util.libId(marketParams) == Util.refId(marketParams);
}

rule checkSummaryMin(uint256 x, uint256 y) {
    uint256 refMin = x < y ? x : y;
    assert Util.libMin(x, y) == refMin;
}

// Check the zeroPreserving summary of ConsistentState.spec: every summarized conversion maps zero to zero.
rule checkSummaryZeroPreserving(uint256 b, uint256 c) {
    assert Util.libMulDivUp(0, b, c) == 0;
    assert Util.libMulDivDown(0, b, c) == 0;
    assert Util.libWDivUp(0, b) == 0;
    assert Util.libWDivDown(0, b) == 0;
    assert Util.libWMulDown(0, b) == 0;
    assert Util.libWTaylorCompounded(0, b) == 0;
    assert Util.toSharesUp(0, b, c) == 0;
    assert Util.toSharesDown(0, b, c) == 0;
    assert Util.toAssetsUp(0, b, c) == 0;
    assert Util.toAssetsDown(0, b, c) == 0;
}

// Check the positivePreserving summary of ConsistentState.spec: the ceil-direction conversions map a positive
// input to a positive output.
rule checkSummaryPositivePreserving(uint256 a, uint256 b, uint256 c) {
    require a > 0;
    assert Util.toSharesUp(a, b, c) > 0;
    assert Util.toAssetsUp(a, b, c) > 0;
}
