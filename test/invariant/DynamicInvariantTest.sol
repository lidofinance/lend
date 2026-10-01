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

    /* AUDIT REACH TESTS */

    // Audit reach test for FZ-01/03/04/05: accrual with a nonzero fee on market 0, then the zero-floor repay on
    // market 1 (a one-share repay removes a whole asset unit, so a later full repay by shares pulls one unit
    // more than the borrow total). Every call goes through the fuzzed handlers as USER.
    function test_auditReach_accrualFeeZeroFloor() public {
        vm.prank(USER);
        this.setFeeNoRevert(0, 0.1e18);
        vm.prank(USER);
        this.supplyAssetsOnBehalfNoRevert(0, 1e24, 0);
        vm.prank(USER);
        this.supplyCollateralOnBehalfNoRevert(0, 1e25, 0);
        vm.prank(USER);
        this.borrowAssetsOnBehalfNoRevert(0, 5e23, 0, RECEIVER);
        this.mine(1 days / BLOCK_TIME);
        vm.prank(USER);
        this.accrueInterestNoRevert(0);

        MarketParams memory m1 = allMarketParams[1];
        vm.prank(USER);
        this.supplyAssetsOnBehalfNoRevert(1, 100, 0);
        vm.prank(USER);
        this.supplyCollateralOnBehalfNoRevert(1, 1e18, 0);
        vm.prank(USER);
        this.borrowAssetsOnBehalfNoRevert(1, 100, 0, RECEIVER);
        vm.prank(USER);
        this.repaySharesOnBehalfNoRevert(1, 1, 0);
        uint256 remaining = morpho.borrowShares(m1.id(), USER);
        vm.prank(USER);
        this.repaySharesOnBehalfNoRevert(1, remaining, 0);

        assertGt(morpho.supplyShares(allMarketParams[0].id(), FEE_RECIPIENT), 0, "reach: fee shares minted");
        assertGt(auditAccruals, 0, "reach FZ-05: accrual checked");
        assertGt(auditAccrualsWithFee, 0, "reach FZ-05: accrual with fee and interest checked");
        assertGt(auditIsolationChecks, 0, "reach FZ-03: isolation checked");
        assertGt(auditRateChecks, 0, "reach FZ-04: rate checked");
        assertGt(auditZeroFloorEvents, 0, "reach FZ-01: zero-floor repay reached");
        assertGt(ghostLoanZeroFloorExcess, 0, "reach FZ-01: zero-floor ghost moved");
        assertEq(morpho.borrowShares(m1.id(), USER), 0, "reach: full repay by shares");
        _assertAllInvariants();
    }

    // Audit reach test for FZ-06: a price crash puts USER underwater, and a full seize realizes bad debt.
    function test_auditReach_liquidationBadDebt() public {
        vm.prank(USER);
        this.supplyAssetsOnBehalfNoRevert(0, 1e24, 0);
        vm.prank(USER);
        this.supplyCollateralOnBehalfNoRevert(0, 1e24, 0);
        vm.prank(USER);
        this.borrowAssetsOnBehalfNoRevert(0, 7.9e23, 0, RECEIVER);
        this.setPrice(MIN_PRICE);
        vm.prank(USER);
        this.liquidateSeizedAssetsNoRevert(0, 1e24, 0);

        Id id0 = allMarketParams[0].id();
        assertEq(morpho.collateral(id0, USER), 0, "reach: full seize");
        assertEq(morpho.borrowShares(id0, USER), 0, "reach: bad debt closed the position");
        assertGt(auditLiquidations, 0, "reach FZ-06: liquidation checked");
        assertGt(auditBadDebtRealizations, 0, "reach FZ-06: bad-debt realization checked");
        _assertAllInvariants();
    }

    function _assertAllInvariants() internal {
        invariantSupplyShares();
        invariantBorrowShares();
        invariantTotalSupplyGeTotalBorrow();
        invariantMorphoBalance();
        invariantBadDebt();
        invariantAggregateLoanCustody();
        invariantAggregateCollateralCustody();
    }

    /* INVARIANTS */

    // Audit FZ-01. All six markets share one loan token, so custody holds only in aggregate: the core's loan
    // balance equals the summed accounting idle plus the zero-floor excess that repay and liquidate leave
    // (`ghostLoanZeroFloorExcess`, built from inputs and pre-state in BaseInvariantTest). Exact.
    function invariantAggregateLoanCustody() public {
        uint256 idle;
        for (uint256 i; i < allMarketParams.length; ++i) {
            Id _id = allMarketParams[i].id();
            idle += morpho.totalSupplyAssets(_id) - morpho.totalBorrowAssets(_id);
        }
        assertEq(loanToken.balanceOf(address(morpho)), idle + ghostLoanZeroFloorExcess, "FZ-01: loan custody");
    }

    // Audit FZ-02. Every collateral token the core holds is recorded on a sender position in one of the six
    // markets. Exact.
    function invariantAggregateCollateralCustody() public {
        address[] memory users = targetSenders();
        uint256 sum;
        for (uint256 i; i < allMarketParams.length; ++i) {
            Id _id = allMarketParams[i].id();
            for (uint256 j; j < users.length; ++j) {
                sum += morpho.collateral(_id, users[j]);
            }
        }
        assertEq(collateralToken.balanceOf(address(morpho)), sum, "FZ-02: collateral custody");
    }

    // Last-run counters only (handler state resets per run); supplementary evidence.
    function afterInvariant() public {
        emit log_named_uint("auditIsolationChecks", auditIsolationChecks);
        emit log_named_uint("auditRateChecks", auditRateChecks);
        emit log_named_uint("auditRateExemptions", auditRateExemptions);
        emit log_named_uint("auditAccruals", auditAccruals);
        emit log_named_uint("auditAccrualsWithFee", auditAccrualsWithFee);
        emit log_named_uint("auditLiquidations", auditLiquidations);
        emit log_named_uint("auditBadDebtRealizations", auditBadDebtRealizations);
        emit log_named_uint("auditZeroFloorEvents", auditZeroFloorEvents);
        emit log_named_uint("ghostLoanZeroFloorExcess", ghostLoanZeroFloorExcess);
    }

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

    function invariantMorphoBalance() public {
        for (uint256 i; i < allMarketParams.length; ++i) {
            MarketParams memory _marketParams = allMarketParams[i];
            Id _id = _marketParams.id();

            assertGe(
                loanToken.balanceOf(address(morpho)) + morpho.totalBorrowAssets(_id), morpho.totalSupplyAssets(_id)
            );
        }
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
}
