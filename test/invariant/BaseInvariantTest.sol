// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../InvariantTest.sol";

contract BaseInvariantTest is InvariantTest {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    using MarketParamsLib for MarketParams;

    address internal immutable USER;

    MarketParams[] internal allMarketParams;

    /* AUDIT GHOSTS AND COUNTERS (read by the invariant contracts through inheritance) */

    /// @dev FZ-01: sum over successful repay/liquidate of max(0, pulled - preTBA). `pulled` is the loan-asset amount
    ///      the core reports it pulls (return value); `preTBA` is the pre-call post-accrual view. Each call adds 0 or 1.
    uint256 internal ghostLoanZeroFloorExcess;

    uint256 internal auditIsolationChecks;
    uint256 internal auditRateChecks;
    uint256 internal auditRateExemptions;
    uint256 internal auditAccruals;
    uint256 internal auditAccrualsWithFee;
    uint256 internal auditLiquidations;
    uint256 internal auditBadDebtRealizations;
    uint256 internal auditZeroFloorEvents;

    /// @dev Pre-call snapshot for one handler call on market `target`.
    struct AuditPre {
        uint256 target;
        bytes32[] others; // hash of every market's struct and USER/FEE_RECIPIENT positions
        uint256 tsa; // post-accrual view (expectedMarketBalances)
        uint256 tss;
        uint256 tba;
        uint256 tbs;
        uint256 coreLoanBalance;
    }

    constructor() {
        USER = makeAddr("User");
    }

    function setUp() public virtual override {
        selectors.push(this.supplyAssetsOnBehalfNoRevert.selector);
        selectors.push(this.supplySharesOnBehalfNoRevert.selector);
        selectors.push(this.withdrawAssetsOnBehalfNoRevert.selector);
        selectors.push(this.borrowAssetsOnBehalfNoRevert.selector);
        selectors.push(this.repayAssetsOnBehalfNoRevert.selector);
        selectors.push(this.repaySharesOnBehalfNoRevert.selector);
        selectors.push(this.supplyCollateralOnBehalfNoRevert.selector);
        selectors.push(this.withdrawCollateralOnBehalfNoRevert.selector);
        selectors.push(this.accrueInterestNoRevert.selector);

        super.setUp();

        allMarketParams.push(marketParams);

        for (uint256 i = 2; i <= 6; ++i) {
            MarketParams memory _marketParams = MarketParams({
                loanToken: address(loanToken),
                collateralToken: address(collateralToken),
                oracle: address(oracle),
                irm: address(irm),
                lltv: MAX_TEST_LLTV / i
            });

            vm.startPrank(OWNER);
            morpho.createMarket(_marketParams);
            vm.stopPrank();

            allMarketParams.push(_marketParams);
        }
    }

    function _targetSenders() internal virtual override {
        _targetSender(USER);
    }

    modifier authorized(address onBehalf) {
        if (onBehalf != msg.sender && !morpho.isAuthorized(onBehalf, msg.sender)) {
            vm.prank(onBehalf);
            morpho.setAuthorization(msg.sender, true);
        }

        _;

        if (morpho.isAuthorized(onBehalf, msg.sender)) {
            vm.prank(onBehalf);
            morpho.setAuthorization(msg.sender, false);
        }
    }

    function _randomMarket(uint256 marketSeed) internal view returns (MarketParams memory _marketParams) {
        return allMarketParams[marketSeed % allMarketParams.length];
    }

    /* AUDIT PER-CALL CHECKS (FZ-01, FZ-03, FZ-04, FZ-05, FZ-06) */

    function _marketIndex(MarketParams memory _marketParams) internal view returns (uint256) {
        Id _id = _marketParams.id();
        for (uint256 i; i < allMarketParams.length; ++i) {
            if (Id.unwrap(allMarketParams[i].id()) == Id.unwrap(_id)) return i;
        }
        revert("audit: unknown market");
    }

    function _marketHash(uint256 i) internal view returns (bytes32) {
        Id _id = allMarketParams[i].id();
        return keccak256(
            abi.encode(morpho.market(_id), morpho.position(_id, USER), morpho.position(_id, FEE_RECIPIENT))
        );
    }

    function _auditBefore(MarketParams memory _marketParams) internal view returns (AuditPre memory pre) {
        pre.target = _marketIndex(_marketParams);
        pre.others = new bytes32[](allMarketParams.length);
        for (uint256 i; i < allMarketParams.length; ++i) {
            pre.others[i] = _marketHash(i);
        }
        (pre.tsa, pre.tss, pre.tba, pre.tbs) = morpho.expectedMarketBalances(_marketParams);
        pre.coreLoanBalance = loanToken.balanceOf(address(morpho));
    }

    /// @dev Pre-call snapshot for an action that does not accrue interest: rate pre-state from stored totals.
    function _auditBeforeStored(MarketParams memory _marketParams) internal view returns (AuditPre memory pre) {
        pre = _auditBefore(_marketParams);
        Market memory m = morpho.market(_marketParams.id());
        (pre.tsa, pre.tss, pre.tba, pre.tbs) =
            (m.totalSupplyAssets, m.totalSupplyShares, m.totalBorrowAssets, m.totalBorrowShares);
    }

    /// @dev a * b < c * d without overflow (512-bit products).
    function _mulLt(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (bool) {
        (uint256 h1, uint256 l1) = _mul512(a, b);
        (uint256 h2, uint256 l2) = _mul512(c, d);
        return h1 < h2 || (h1 == h2 && l1 < l2);
    }

    function _mul512(uint256 a, uint256 b) internal pure returns (uint256 hi, uint256 lo) {
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
    }

    /// @dev FZ-03 isolation and FZ-04 rate monotonicity after a successful call on `pre.target`.
    ///      `badDebtExempt` exempts both rate checks (bad-debt realization); the borrow side is also exempt when the
    ///      post-state has zero borrow assets or zero borrow shares. Exemptions are counted, never silent.
    function _auditAfter(AuditPre memory pre, bool badDebtExempt) internal {
        for (uint256 i; i < allMarketParams.length; ++i) {
            if (i == pre.target) continue;
            assertEq(_marketHash(i), pre.others[i], "FZ-03: call changed another market or its positions");
        }
        ++auditIsolationChecks;

        Market memory m = morpho.market(allMarketParams[pre.target].id());
        if (badDebtExempt) {
            ++auditRateExemptions;
            return;
        }
        // Supply rate never falls: (TSA'+1)(preTSS+1e6) >= (preTSA+1)(TSS'+1e6).
        assertFalse(
            _mulLt(
                uint256(m.totalSupplyAssets) + SharesMathLib.VIRTUAL_ASSETS,
                pre.tss + SharesMathLib.VIRTUAL_SHARES,
                pre.tsa + SharesMathLib.VIRTUAL_ASSETS,
                uint256(m.totalSupplyShares) + SharesMathLib.VIRTUAL_SHARES
            ),
            "FZ-04: supply share rate decreased"
        );
        if (m.totalBorrowAssets == 0 || m.totalBorrowShares == 0) {
            ++auditRateExemptions;
        } else {
            // Borrow rate never rises outside accrual: (TBA'+1)(preTBS+1e6) <= (preTBA+1)(TBS'+1e6).
            assertFalse(
                _mulLt(
                    pre.tba + SharesMathLib.VIRTUAL_ASSETS,
                    uint256(m.totalBorrowShares) + SharesMathLib.VIRTUAL_SHARES,
                    uint256(m.totalBorrowAssets) + SharesMathLib.VIRTUAL_ASSETS,
                    pre.tbs + SharesMathLib.VIRTUAL_SHARES
                ),
                "FZ-04: borrow share rate increased"
            );
        }
        ++auditRateChecks;
    }

    /// @dev FZ-01 ghost update for a successful repay/liquidate that pulled `pulled` loan assets.
    function _auditZeroFloor(AuditPre memory pre, uint256 pulled) internal {
        assertEq(
            loanToken.balanceOf(address(morpho)), pre.coreLoanBalance + pulled, "FZ-01: core pulled the reported assets"
        );
        uint256 excess = pulled > pre.tba ? pulled - pre.tba : 0;
        assertLe(excess, 1, "FZ-01: zero-floor excess above one unit");
        if (excess != 0) {
            ghostLoanZeroFloorExcess += excess;
            ++auditZeroFloorEvents;
        }
    }

    /// @dev FZ-06 (a)-(d) for one successful core liquidation. Returns whether bad debt was realized.
    struct LiquidationPre {
        address borrower;
        uint256 collateral;
        uint256 debtUp;
        bool healthy;
    }

    function _auditLiquidation(
        MarketParams memory _marketParams,
        AuditPre memory pre,
        LiquidationPre memory lp,
        uint256 repaidAssets
    ) internal returns (bool badDebt) {
        Id _id = _marketParams.id();
        Market memory m = morpho.market(_id);
        uint256 postCollateral = morpho.collateral(_id, lp.borrower);

        assertFalse(lp.healthy, "FZ-06a: liquidated a healthy position");
        assertLe(postCollateral, lp.collateral, "FZ-06: collateral grew on liquidation");
        assertLe(
            (lp.collateral - postCollateral).mulDivDown(oracle.price(), ORACLE_PRICE_SCALE),
            repaidAssets.mulDivUp(_liquidationIncentiveFactor(_marketParams.lltv), WAD) + 1,
            "FZ-06b: seized value above repaid times incentive"
        );
        assertLe(repaidAssets, lp.debtUp, "FZ-06c: repaid above pre-call debt");
        if (postCollateral == 0) {
            assertEq(morpho.borrowShares(_id, lp.borrower), 0, "FZ-06d: zero collateral left borrow shares");
            uint256 floored = pre.tba > repaidAssets ? pre.tba - repaidAssets : 0;
            assertGe(pre.tsa, m.totalSupplyAssets, "FZ-06d: supply grew on liquidation");
            assertGe(floored, m.totalBorrowAssets, "FZ-06d: borrow assets above floored repay");
            assertEq(
                pre.tsa - m.totalSupplyAssets,
                floored - m.totalBorrowAssets,
                "FZ-06d: supply write-down differs from bad-debt borrow write-down"
            );
            badDebt = pre.tsa != m.totalSupplyAssets;
        } else {
            assertEq(m.totalSupplyAssets, pre.tsa, "FZ-06d: supply changed without bad debt");
        }
        ++auditLiquidations;
        if (badDebt) ++auditBadDebtRealizations;
    }

    function _supplyAssets(MarketParams memory _marketParams, uint256 assets, address onBehalf)
        internal
        logCall("supplyAssets")
    {
        loanToken.setBalance(msg.sender, assets);

        AuditPre memory pre = _auditBefore(_marketParams);
        vm.prank(msg.sender);
        morpho.supply(_marketParams, assets, 0, onBehalf, hex"");
        _auditAfter(pre, false);
    }

    function _supplyShares(MarketParams memory _marketParams, uint256 shares, address onBehalf)
        internal
        logCall("supplyShares")
    {
        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) = morpho.expectedMarketBalances(_marketParams);

        loanToken.setBalance(msg.sender, shares.toAssetsUp(totalSupplyAssets, totalSupplyShares));

        AuditPre memory pre = _auditBefore(_marketParams);
        vm.prank(msg.sender);
        morpho.supply(_marketParams, 0, shares, onBehalf, hex"");
        _auditAfter(pre, false);
    }

    function _withdraw(
        MarketParams memory _marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) internal authorized(onBehalf) logCall("withdraw") {
        AuditPre memory pre = _auditBefore(_marketParams);
        vm.prank(msg.sender);
        morpho.withdraw(_marketParams, assets, shares, onBehalf, receiver);
        _auditAfter(pre, false);
    }

    function _borrow(
        MarketParams memory _marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) internal authorized(onBehalf) logCall("borrow") {
        AuditPre memory pre = _auditBefore(_marketParams);
        vm.prank(msg.sender);
        morpho.borrow(_marketParams, assets, shares, onBehalf, receiver);
        _auditAfter(pre, false);
    }

    function _repayAssets(MarketParams memory _marketParams, uint256 assets, address onBehalf)
        internal
        logCall("repayAssets")
    {
        loanToken.setBalance(msg.sender, assets);

        AuditPre memory pre = _auditBefore(_marketParams);
        vm.prank(msg.sender);
        (uint256 repaid,) = morpho.repay(_marketParams, assets, 0, onBehalf, hex"");
        _auditZeroFloor(pre, repaid);
        _auditAfter(pre, false);
    }

    function _repayShares(MarketParams memory _marketParams, uint256 shares, address onBehalf)
        internal
        logCall("repayShares")
    {
        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) = morpho.expectedMarketBalances(_marketParams);

        loanToken.setBalance(msg.sender, shares.toAssetsUp(totalBorrowAssets, totalBorrowShares));

        AuditPre memory pre = _auditBefore(_marketParams);
        vm.prank(msg.sender);
        (uint256 repaid,) = morpho.repay(_marketParams, 0, shares, onBehalf, hex"");
        _auditZeroFloor(pre, repaid);
        _auditAfter(pre, false);
    }

    function _supplyCollateral(MarketParams memory _marketParams, uint256 assets, address onBehalf)
        internal
        logCall("supplyCollateral")
    {
        collateralToken.setBalance(msg.sender, assets);

        // `supplyCollateral` does not accrue interest, so its rate pre-state is the stored totals, not the view.
        AuditPre memory pre = _auditBeforeStored(_marketParams);
        vm.prank(msg.sender);
        morpho.supplyCollateral(_marketParams, assets, onBehalf, hex"");
        _auditAfter(pre, false);
    }

    function _withdrawCollateral(MarketParams memory _marketParams, uint256 assets, address onBehalf, address receiver)
        internal
        authorized(onBehalf)
        logCall("withdrawCollateral")
    {
        AuditPre memory pre = _auditBefore(_marketParams);
        vm.prank(msg.sender);
        morpho.withdrawCollateral(_marketParams, assets, onBehalf, receiver);
        _auditAfter(pre, false);
    }

    function _liquidateSeizedAssets(MarketParams memory _marketParams, address borrower, uint256 seizedAssets)
        internal
        logCall("liquidateSeizedAssets")
    {
        uint256 collateralPrice = oracle.price();
        uint256 liquidationIncentiveFactor = _liquidationIncentiveFactor(_marketParams.lltv);
        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) = morpho.expectedMarketBalances(_marketParams);
        uint256 seizedAssetsQuoted = seizedAssets.mulDivUp(collateralPrice, ORACLE_PRICE_SCALE);
        uint256 repaidShares =
            seizedAssetsQuoted.wDivUp(liquidationIncentiveFactor).toSharesUp(totalBorrowAssets, totalBorrowShares);
        uint256 repaidAssets = repaidShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);

        loanToken.setBalance(msg.sender, repaidAssets);

        _liquidateAudited(_marketParams, borrower, seizedAssets, 0);
    }

    function _liquidateRepaidShares(MarketParams memory _marketParams, address borrower, uint256 repaidShares)
        internal
        logCall("liquidateRepaidShares")
    {
        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) = morpho.expectedMarketBalances(_marketParams);

        loanToken.setBalance(msg.sender, repaidShares.toAssetsUp(totalBorrowAssets, totalBorrowShares));

        _liquidateAudited(_marketParams, borrower, 0, repaidShares);
    }

    function _liquidateAudited(
        MarketParams memory _marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares
    ) internal {
        AuditPre memory pre = _auditBefore(_marketParams);
        LiquidationPre memory lp = LiquidationPre({
            borrower: borrower,
            collateral: morpho.collateral(_marketParams.id(), borrower),
            debtUp: morpho.expectedBorrowAssets(_marketParams, borrower),
            healthy: _isHealthy(_marketParams, borrower)
        });

        vm.prank(msg.sender);
        (, uint256 repaid) = morpho.liquidate(_marketParams, borrower, seizedAssets, repaidShares, hex"");

        _auditZeroFloor(pre, repaid);
        bool badDebt = _auditLiquidation(_marketParams, pre, lp, repaid);
        _auditAfter(pre, badDebt);
    }

    /* HANDLERS */

    function setFeeNoRevert(uint256 marketSeed, uint256 newFee) external {
        MarketParams memory _marketParams = _randomMarket(marketSeed);
        Id _id = _marketParams.id();

        newFee = bound(newFee, 0, MAX_FEE);
        if (newFee == morpho.fee(_id)) return;

        AuditPre memory pre = _auditBefore(_marketParams);
        vm.prank(OWNER);
        morpho.setFee(_marketParams, newFee);
        _auditAfter(pre, false);
    }

    /// @dev FZ-05: explicit accrual. The stored post-state equals the pre-call view; supply and borrow assets grow by
    ///      the same interest; supply shares grow only by the fee recipient's shares; USER is untouched; the fee
    ///      shares are worth `v` with `F - ceil(P') <= v <= F`; both share rates are non-decreasing.
    function accrueInterestNoRevert(uint256 marketSeed) external {
        MarketParams memory _marketParams = _randomMarket(marketSeed);
        Id _id = _marketParams.id();

        Market memory s = morpho.market(_id);
        (uint256 eTsa, uint256 eTss, uint256 eTba, uint256 eTbs) = morpho.expectedMarketBalances(_marketParams);
        Position memory userBefore = morpho.position(_id, USER);
        uint256 feeSharesBefore = morpho.supplyShares(_id, FEE_RECIPIENT);
        AuditPre memory pre = _auditBefore(_marketParams);

        morpho.accrueInterest(_marketParams);

        Market memory t = morpho.market(_id);
        assertEq(t.totalSupplyAssets, eTsa, "FZ-05: accrued supply assets differ from the view");
        assertEq(t.totalSupplyShares, eTss, "FZ-05: accrued supply shares differ from the view");
        assertEq(t.totalBorrowAssets, eTba, "FZ-05: accrued borrow assets differ from the view");
        assertEq(t.totalBorrowShares, eTbs, "FZ-05: accrued borrow shares differ from the view");
        assertEq(t.totalBorrowShares, s.totalBorrowShares, "FZ-05: accrual changed borrow shares");

        assertGe(t.totalBorrowAssets, s.totalBorrowAssets, "FZ-05: accrual lowered borrow assets");
        uint256 interest = uint256(t.totalBorrowAssets) - s.totalBorrowAssets;
        assertEq(uint256(t.totalSupplyAssets) - s.totalSupplyAssets, interest, "FZ-05: supply delta != borrow delta");

        uint256 feeShares = morpho.supplyShares(_id, FEE_RECIPIENT) - feeSharesBefore;
        assertEq(
            uint256(t.totalSupplyShares) - s.totalSupplyShares, feeShares, "FZ-05: supply shares minted beyond fee"
        );
        assertEq(
            keccak256(abi.encode(morpho.position(_id, USER))),
            keccak256(abi.encode(userBefore)),
            "FZ-05: accrual changed USER position"
        );

        if (s.fee != 0 && interest != 0) {
            uint256 feeAmount = interest.wMulDown(s.fee);
            uint256 value = feeShares.toAssetsDown(t.totalSupplyAssets, t.totalSupplyShares);
            uint256 ceilPrice = (uint256(t.totalSupplyAssets) + SharesMathLib.VIRTUAL_ASSETS).mulDivUp(
                1, uint256(t.totalSupplyShares) + SharesMathLib.VIRTUAL_SHARES
            );
            assertLe(value, feeAmount, "FZ-05: fee shares worth more than the fee");
            assertGe(value + ceilPrice, feeAmount, "FZ-05: fee shares worth less than fee - ceil(P')");
            ++auditAccrualsWithFee;
        }

        // Both rates non-decreasing across accrual (against the stored pre-state).
        assertFalse(
            _mulLt(
                uint256(t.totalSupplyAssets) + SharesMathLib.VIRTUAL_ASSETS,
                uint256(s.totalSupplyShares) + SharesMathLib.VIRTUAL_SHARES,
                uint256(s.totalSupplyAssets) + SharesMathLib.VIRTUAL_ASSETS,
                uint256(t.totalSupplyShares) + SharesMathLib.VIRTUAL_SHARES
            ),
            "FZ-05: supply share rate decreased on accrual"
        );
        assertFalse(
            _mulLt(
                uint256(t.totalBorrowAssets) + SharesMathLib.VIRTUAL_ASSETS,
                uint256(s.totalBorrowShares) + SharesMathLib.VIRTUAL_SHARES,
                uint256(s.totalBorrowAssets) + SharesMathLib.VIRTUAL_ASSETS,
                uint256(t.totalBorrowShares) + SharesMathLib.VIRTUAL_SHARES
            ),
            "FZ-05: borrow share rate decreased on accrual"
        );
        ++auditAccruals;

        // Isolation only: the view-based rate checks of `_auditAfter` are equalities here and add nothing.
        for (uint256 i; i < allMarketParams.length; ++i) {
            if (i == pre.target) continue;
            assertEq(_marketHash(i), pre.others[i], "FZ-03: accrual changed another market or its positions");
        }
        ++auditIsolationChecks;
    }

    function supplyAssetsOnBehalfNoRevert(uint256 marketSeed, uint256 assets, uint256 onBehalfSeed) external {
        MarketParams memory _marketParams = _randomMarket(marketSeed);

        address onBehalf = _randomCandidate(targetSenders(), onBehalfSeed);

        assets = _boundSupplyAssets(_marketParams, USER, assets);
        if (assets == 0) return;

        _supplyAssets(_marketParams, assets, onBehalf);
    }

    function supplySharesOnBehalfNoRevert(uint256 marketSeed, uint256 shares, uint256 onBehalfSeed) external {
        MarketParams memory _marketParams = _randomMarket(marketSeed);

        address onBehalf = _randomCandidate(targetSenders(), onBehalfSeed);

        shares = _boundSupplyShares(_marketParams, onBehalf, shares);
        if (shares == 0) return;

        _supplyShares(_marketParams, shares, onBehalf);
    }

    function withdrawAssetsOnBehalfNoRevert(uint256 marketSeed, uint256 assets, uint256 onBehalfSeed, address receiver)
        external
    {
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(morpho)); // audit FZ-01/02: a self-transfer would break exact custody

        MarketParams memory _marketParams = _randomMarket(marketSeed);

        address onBehalf = _randomSupplier(targetSenders(), _marketParams, onBehalfSeed);
        if (onBehalf == address(0)) return;

        assets = _boundWithdrawAssets(_marketParams, onBehalf, assets);
        if (assets == 0) return;

        _withdraw(_marketParams, assets, 0, onBehalf, receiver);
    }

    function borrowAssetsOnBehalfNoRevert(uint256 marketSeed, uint256 assets, uint256 onBehalfSeed, address receiver)
        external
    {
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(morpho)); // audit FZ-01/02: a self-transfer would break exact custody

        MarketParams memory _marketParams = _randomMarket(marketSeed);

        address onBehalf = _randomHealthyCollateralSupplier(targetSenders(), _marketParams, onBehalfSeed);
        if (onBehalf == address(0)) return;

        assets = _boundBorrowAssets(_marketParams, onBehalf, assets);
        if (assets == 0) return;

        _borrow(_marketParams, assets, 0, onBehalf, receiver);
    }

    function repayAssetsOnBehalfNoRevert(uint256 marketSeed, uint256 assets, uint256 onBehalfSeed) external {
        MarketParams memory _marketParams = _randomMarket(marketSeed);

        address onBehalf = _randomBorrower(targetSenders(), _marketParams, onBehalfSeed);
        if (onBehalf == address(0)) return;

        assets = _boundRepayAssets(_marketParams, onBehalf, assets);
        if (assets == 0) return;

        _repayAssets(_marketParams, assets, onBehalf);
    }

    function repaySharesOnBehalfNoRevert(uint256 marketSeed, uint256 shares, uint256 onBehalfSeed) external {
        MarketParams memory _marketParams = _randomMarket(marketSeed);

        address onBehalf = _randomBorrower(targetSenders(), _marketParams, onBehalfSeed);
        if (onBehalf == address(0)) return;

        shares = _boundRepayShares(_marketParams, onBehalf, shares);
        if (shares == 0) return;

        _repayShares(_marketParams, shares, onBehalf);
    }

    function supplyCollateralOnBehalfNoRevert(uint256 marketSeed, uint256 assets, uint256 onBehalfSeed) external {
        MarketParams memory _marketParams = _randomMarket(marketSeed);

        address onBehalf = _randomCandidate(targetSenders(), onBehalfSeed);

        assets = _boundSupplyCollateralAssets(_marketParams, onBehalf, assets);
        if (assets == 0) return;

        _supplyCollateral(_marketParams, assets, onBehalf);
    }

    function withdrawCollateralOnBehalfNoRevert(
        uint256 marketSeed,
        uint256 assets,
        uint256 onBehalfSeed,
        address receiver
    ) external {
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(morpho)); // audit FZ-01/02: a self-transfer would break exact custody

        MarketParams memory _marketParams = _randomMarket(marketSeed);

        address onBehalf = _randomHealthyCollateralSupplier(targetSenders(), _marketParams, onBehalfSeed);
        if (onBehalf == address(0)) return;

        assets = _boundWithdrawCollateralAssets(_marketParams, onBehalf, assets);
        if (assets == 0) return;

        _withdrawCollateral(_marketParams, assets, onBehalf, receiver);
    }

    function liquidateSeizedAssetsNoRevert(uint256 marketSeed, uint256 seizedAssets, uint256 borrowerSeed) external {
        MarketParams memory _marketParams = _randomMarket(marketSeed);

        address borrower = _randomUnhealthyBorrower(targetSenders(), _marketParams, borrowerSeed);
        if (borrower == address(0)) return;

        seizedAssets = _boundLiquidateSeizedAssets(_marketParams, borrower, seizedAssets);
        if (seizedAssets == 0) return;

        _liquidateSeizedAssets(_marketParams, borrower, seizedAssets);
    }

    function liquidateRepaidSharesNoRevert(uint256 marketSeed, uint256 repaidShares, uint256 borrowerSeed) external {
        MarketParams memory _marketParams = _randomMarket(marketSeed);

        address borrower = _randomUnhealthyBorrower(targetSenders(), _marketParams, borrowerSeed);
        if (borrower == address(0)) return;

        repaidShares = _boundLiquidateRepaidShares(_marketParams, borrower, repaidShares);
        if (repaidShares == 0) return;

        _liquidateRepaidShares(_marketParams, borrower, repaidShares);
    }
}
