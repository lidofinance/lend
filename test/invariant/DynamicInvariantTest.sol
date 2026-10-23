// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./BaseInvariantTest.sol";

contract DynamicInvariantTest is BaseInvariantTest {
    using MorphoLib for IMorpho;
    using MarketParamsLib for MarketParams;

    uint256 internal immutable MIN_PRICE = ORACLE_PRICE_SCALE / 10;
    uint256 internal immutable MAX_PRICE = ORACLE_PRICE_SCALE * 10;

    function setUp() public virtual override {
        selectors.push(this.liquidateSeizedAssetsNoRevert.selector);
        selectors.push(this.liquidateRepaidSharesNoRevert.selector);
        selectors.push(this.setFeeNoRevert.selector);
        selectors.push(this.setPrice.selector);
        selectors.push(this.mine.selector);

        super.setUp();
    }

    /* HANDLERS */

    function setPrice(uint256 price) external {
        price = bound(price, MIN_PRICE, MAX_PRICE);

        oracle.setPrice(price);
    }

    /* HELPERS */

    // A market's free liquidity is its claim on the loan token. Every market in `allMarketParams` names the
    // same token, so the claims all land on one balance and only their sum bounds it.
    function _loanTokenClaims() internal view returns (uint256 claims) {
        for (uint256 i; i < allMarketParams.length; ++i) {
            Id _id = allMarketParams[i].id();

            claims += morpho.totalSupplyAssets(_id) - morpho.totalBorrowAssets(_id);
        }
    }

    // Collateral is custodied per position, so the claim is the sum over every market and every position
    // holder. `targetSenders()` is the complete holder set: handlers only ever pass one of them as `onBehalf`.
    function _collateralTokenClaims() internal view returns (uint256 claims) {
        address[] memory users = targetSenders();

        for (uint256 i; i < allMarketParams.length; ++i) {
            Id _id = allMarketParams[i].id();

            for (uint256 j; j < users.length; ++j) {
                claims += morpho.collateral(_id, users[j]);
            }
        }
    }

    /* INVARIANTS */

    function invariantSupplyShares() public {
        address[] memory users = targetSenders();

        for (uint256 i; i < allMarketParams.length; ++i) {
            MarketParams memory _marketParams = allMarketParams[i];
            Id _id = _marketParams.id();

            uint256 sumSupplyShares = morpho.supplyShares(_id, FEE_RECIPIENT);
            for (uint256 j; j < users.length; ++j) {
                sumSupplyShares += morpho.supplyShares(_id, users[j]);
            }

            assertEq(sumSupplyShares, morpho.totalSupplyShares(_id), vm.toString(_marketParams.lltv));
        }
    }

    function invariantBorrowShares() public {
        address[] memory users = targetSenders();

        for (uint256 i; i < allMarketParams.length; ++i) {
            MarketParams memory _marketParams = allMarketParams[i];
            Id _id = _marketParams.id();

            uint256 sumBorrowShares;
            for (uint256 j; j < users.length; ++j) {
                sumBorrowShares += morpho.borrowShares(_id, users[j]);
            }

            assertEq(sumBorrowShares, morpho.totalBorrowShares(_id), vm.toString(_marketParams.lltv));
        }
    }

    function invariantTotalSupplyGeTotalBorrow() public {
        for (uint256 i; i < allMarketParams.length; ++i) {
            MarketParams memory _marketParams = allMarketParams[i];
            Id _id = _marketParams.id();

            assertGe(morpho.totalSupplyAssets(_id), morpho.totalBorrowAssets(_id));
        }
    }

    // Covered, never matched: the balance also absorbs tokens that reach the core outside its accounting,
    // such as a withdrawal whose receiver is the core itself.
    function invariantMorphoBalance() public {
        assertGe(loanToken.balanceOf(address(morpho)), _loanTokenClaims(), "loan custody");
    }

    function invariantMorphoCollateralBalance() public {
        // The two sums are per token. They may only be checked separately while the tokens are distinct.
        assertTrue(address(loanToken) != address(collateralToken), "fixture: distinct tokens");

        assertGe(collateralToken.balanceOf(address(morpho)), _collateralTokenClaims(), "collateral custody");
    }

    function invariantBadDebt() public {
        address[] memory users = targetSenders();

        for (uint256 i; i < allMarketParams.length; ++i) {
            MarketParams memory _marketParams = allMarketParams[i];
            Id _id = _marketParams.id();

            for (uint256 j; j < users.length; ++j) {
                address user = users[j];

                if (morpho.collateral(_id, user) == 0) {
                    assertEq(
                        morpho.borrowShares(_id, user),
                        0,
                        string.concat(vm.toString(_marketParams.lltv), ":", vm.toString(user))
                    );
                }
            }
        }
    }

    /* DETERMINISTIC TESTS */

    // Keeps `invariantMorphoBalance` from passing vacuously. The campaign only ever visits states the core
    // itself produces, so it cannot show that the check rejects anything. This builds the shortfall the core
    // must never produce and asserts the comparison refuses it. Two markets, because a shortfall spread
    // across markets is the one a balance compared against a single market's claim cannot see.
    function testMorphoBalanceDetectsCustodyShortfall() public {
        uint256 claim = MIN_TEST_AMOUNT;
        MarketParams memory first = allMarketParams[0];
        MarketParams memory second = allMarketParams[1];

        loanToken.setBalance(USER, 2 * claim);
        vm.startPrank(USER);
        morpho.supply(first, claim, 0, USER, hex"");
        morpho.supply(second, claim, 0, USER, hex"");
        vm.stopPrank();

        // No handler can reach this state: `setBalance` stands in for a custody loss the core cannot cause.
        loanToken.setBalance(address(morpho), claim);

        uint256 balance = loanToken.balanceOf(address(morpho));

        assertGe(
            balance + morpho.totalBorrowAssets(first.id()),
            morpho.totalSupplyAssets(first.id()),
            "the first market alone looks covered"
        );
        assertGe(
            balance + morpho.totalBorrowAssets(second.id()),
            morpho.totalSupplyAssets(second.id()),
            "the second market alone looks covered"
        );

        assertEq(_loanTokenClaims(), 2 * claim, "both markets claim the shared balance");
        // The state is deliberately broken, so the invariant's comparison must reject it.
        assertLt(balance, _loanTokenClaims(), "the summed claim rejects the shortfall");
    }
}
