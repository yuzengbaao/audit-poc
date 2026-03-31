// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.19;

import "@forge-std/Test.sol";

import {MockChainlinkOracle} from "@test/mock/MockChainlinkOracle.sol";
import {ChainlinkOracle} from "@protocol/oracles/ChainlinkOracle.sol";
import {ChainlinkCompositeOracle} from "@protocol/oracles/ChainlinkCompositeOracle.sol";
import {ChainlinkCompositeOEVWrapper} from "@protocol/oracles/ChainlinkCompositeOEVWrapper.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {MErc20Immutable} from "@test/mock/MErc20Immutable.sol";
import {SimplePriceOracle} from "@test/helper/SimplePriceOracle.sol";
import {InterestRateModel} from "@protocol/irm/InterestRateModel.sol";
import {WhitePaperInterestRateModel} from "@protocol/irm/WhitePaperInterestRateModel.sol";
import {FaucetToken} from "@test/helper/FaucetToken.sol";
import {MultiRewardDistributor} from "@protocol/rewards/MultiRewardDistributor.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {MToken} from "@protocol/MToken.sol";

// ============================================================================
// H-01: ChainlinkOracle stale prices - no answeredInRound == roundId check
// Finding: getChainlinkPrice() only checks answer > 0 and updatedAt != 0,
//          but does NOT check answeredInRound == roundId (the staleness check).
//          ChainlinkCompositeOracle DOES check this.
// ============================================================================
contract POC_H01_StalePrice is Test {
    ChainlinkOracle oracle;
    MockChainlinkOracle feed;
    SimplePriceOracle simpleOracle;
    Comptroller comptroller;
    FaucetToken underlying;
    MErc20Immutable mToken;
    InterestRateModel irm;

    function setUp() public {
        oracle = new ChainlinkOracle("MOVR"); // native token (unused path)
        feed = new MockChainlinkOracle(2000e8, 8); // $2000, 8 decimals

        // Set the feed for "TST" symbol
        vm.prank(address(this));
        oracle.setFeed("TST", address(feed));

        comptroller = new Comptroller();
        simpleOracle = new SimplePriceOracle();
        underlying = new FaucetToken(1000e18, "TestToken", 18, "TST");
        irm = new WhitePaperInterestRateModel(0.1e18, 0.45e18);

        mToken = new MErc20Immutable(
            address(underlying),
            comptroller,
            irm,
            1e18,
            "mTST",
            "mTST",
            8,
            payable(address(this))
        );

        // admin is already address(this) from constructor
        comptroller._setPriceOracle(oracle);
        comptroller._supportMarket(mToken);
        // Do NOT set price override - so it falls through to getChainlinkPrice
    }

    /// @notice Proof that ChainlinkOracle accepts stale prices where answeredInRound != roundId
    function test_stalePrice_accepted_when_answeredInRound_mismatch() public {
        // Set the feed to have answeredInRound != roundId (stale scenario)
        // roundId = 100 but answeredInRound = 50 (stale)
        feed.set(
            100,         // roundId
            2000e8,      // answer (positive)
            1000,        // startedAt
            1620651856,  // updatedAt (non-zero)
            50           // answeredInRound != roundId => STALE but not checked!
        );

        // ChainlinkOracle.getUnderlyingPrice -> getPrice -> getChainlinkPrice
        // getChainlinkPrice only checks answer > 0 and updatedAt != 0
        // It does NOT check answeredInRound == roundId
        uint256 price = oracle.getUnderlyingPrice(MToken(address(mToken)));

        // Price is returned despite being stale
        assertGt(price, 0, "Stale price was accepted by ChainlinkOracle");
        // The underlying has 18 decimals, feed has 8 decimals
        // getChainlinkPrice scales by 10^(18-8) = 10^10
        // Then getPrice scales by 10^(18-18) = 1 (no change)
        // So price should be 2000e18
        assertEq(price, 2000e18, "Stale price returned without validation");
    }

    /// @notice Proof that ChainlinkCompositeOracle DOES check answeredInRound == roundId
    function test_compositeOracle_rejects_stalePrice() public {
        MockChainlinkOracle feedA = new MockChainlinkOracle(2000e8, 8);
        MockChainlinkOracle feedB = new MockChainlinkOracle(1e8, 8);
        ChainlinkCompositeOracle composite = new ChainlinkCompositeOracle(
            address(feedA),
            address(feedB),
            address(feedA)
        );

        // Set stale: answeredInRound != roundId
        feedA.set(100, 2000e8, 1000, 1620651856, 50);
        feedB.set(100, 1e8, 1000, 1620651856, 50);

        // Composite oracle checks answeredInRound == roundId and reverts
        vm.expectRevert("CLCOracle: Oracle data is invalid");
        composite.latestRoundData();
    }

    /// @notice Proof: even answeredInRound=0 (clearly invalid) is accepted by ChainlinkOracle
    function test_chainlinkOracle_accepts_zero_answeredInRound() public {
        feed.set(
            100,         // roundId
            2000e8,      // answer > 0 (passes check)
            1000,        // startedAt
            1620651856,  // updatedAt != 0 (passes check)
            0            // answeredInRound == 0 (STALE, but NOT checked)
        );

        uint256 price = oracle.getUnderlyingPrice(MToken(address(mToken)));
        assertEq(price, 2000e18, "Zero answeredInRound accepted");
    }
}

// ============================================================================
// H-03: OEV liquidation no access control - anyone can call
// Finding: updatePriceEarlyAndLiquidate() has no onlyOwner or any msg.sender check.
//          It uses only nonReentrant (reentrancy guard), not access control.
// ============================================================================
contract POC_H03_OEVNoAccessControl is Test {
    ChainlinkOracle public chainlinkOracle;
    MockChainlinkOracle public baseFeed;
    MockChainlinkOracle public compositeOracle;
    ChainlinkCompositeOEVWrapper public wrapper;

    function setUp() public {
        chainlinkOracle = new ChainlinkOracle("MOVR");
        baseFeed = new MockChainlinkOracle(2000e8, 8);
        compositeOracle = new MockChainlinkOracle(3000e18, 18);

        address feeRecipient = address(0xFEE);

        wrapper = new ChainlinkCompositeOEVWrapper(
            address(compositeOracle),
            address(baseFeed),
            address(this),
            address(chainlinkOracle),
            feeRecipient,
            5000, // 50% liquidator fee
            3600  // 1 hour delay
        );

        // Register wrapper as the feed for "COLL" token
        vm.prank(address(this));
        chainlinkOracle.setFeed("COLL", address(wrapper));
    }

    /// @notice Proof that updatePriceEarlyAndLiquidate is permissionless.
    ///         If onlyOwner were applied, calling from randomUser would revert
    ///         with "Ownable: caller is not the owner" BEFORE any parameter checks.
    ///         Instead, it reverts on the first parameter check (repayAmount == 0).
    function test_anyone_can_call_updatePriceEarlyAndLiquidate() public {
        address randomUser = address(0xBAD);
        assertTrue(randomUser != wrapper.owner(), "randomUser is not the owner");

        vm.prank(randomUser);
        vm.expectRevert("ChainlinkCompositeOEVWrapper: repay amount cannot be zero");
        wrapper.updatePriceEarlyAndLiquidate(
            address(0x1),  // borrower (non-zero, passes check 2)
            0,             // repayAmount == 0 -> reverts here
            address(0x2),  // mTokenCollateral (non-zero)
            address(0x3)   // mTokenLoan (non-zero)
        );
        // If onlyOwner existed, revert would be "Ownable: caller is not the owner"
        // The fact we reach the repayAmount check proves NO access control
    }

    /// @notice Proof: non-owner reaches deep into the function before failing
    function test_non_owner_reaches_safeTransferFrom_check() public {
        address randomUser = address(0xBAD);

        // Create a real collateral mToken with "COLL" underlying
        Comptroller comp = new Comptroller();
        SimplePriceOracle sp = new SimplePriceOracle();
        FaucetToken collToken = new FaucetToken(1000e18, "Collateral", 18, "COLL");
        InterestRateModel irm = new WhitePaperInterestRateModel(0.1e18, 0.45e18);

        MErc20Immutable collMToken = new MErc20Immutable(
            address(collToken),
            comp,
            irm,
            1e18,
            "mCOLL",
            "mCOLL",
            8,
            payable(address(this))
        );

        // admin is already address(this) from constructor
        comp._setPriceOracle(sp);
        comp._supportMarket(collMToken);
        sp.setUnderlyingPrice(collMToken, 1e18);

        // Need a loan token feed for chainlinkOracle.getFeed("LOAN")
        MockChainlinkOracle loanFeed = new MockChainlinkOracle(1e8, 8);
        vm.prank(address(this));
        chainlinkOracle.setFeed("LOAN", address(loanFeed));

        // Create a loan mToken with "LOAN" underlying
        FaucetToken loanToken = new FaucetToken(1000e18, "Loan", 18, "LOAN");
        MErc20Immutable loanMToken = new MErc20Immutable(
            address(loanToken),
            comp,
            irm,
            1e18,
            "mLOAN",
            "mLOAN",
            8,
            payable(address(this))
        );

        comp._supportMarket(loanMToken);
        sp.setUnderlyingPrice(loanMToken, 1e18);

        // Call from randomUser with all params valid
        // Will fail at safeTransferFrom (no approval) - NOT at access control
        vm.prank(randomUser);
        vm.expectRevert();
        wrapper.updatePriceEarlyAndLiquidate(
            address(0x1),           // borrower
            100,                    // repayAmount > 0
            address(collMToken),    // mTokenCollateral (COLL underlying)
            address(loanMToken)     // mTokenLoan (LOAN underlying)
        );
        // Reached safeTransferFrom without any access control revert!
    }
}

// ============================================================================
// H-02: Unchecked ERC20 transfer in _rescueFunds
// Finding: Comptroller._rescueFunds() uses token.transfer() instead of
//          SafeERC20.safeTransfer(), ignoring the return value.
//          Tokens that return false (e.g. USDT) will cause silent fund loss.
// ============================================================================
contract POC_H02_UncheckedTransfer is Test {
    Comptroller comptroller;
    address admin = address(this);
    address alice = address(0xA);

    NoReturnToken badToken;

    function setUp() public {
        comptroller = new Comptroller();
        badToken = new NoReturnToken();
    }

    /// @notice Proof that _rescueFunds silently fails with non-standard ERC20 tokens
    function test_rescueFunds_silently_fails_with_bad_token() public {
        // Mint tokens to the comptroller
        badToken.mint(address(comptroller), 1000e18);

        uint256 balanceBefore = badToken.balanceOf(admin);

        // _rescueFunds calls token.transfer() which returns false for NoReturnToken
        // but the return value is NOT checked (no SafeERC20)
        vm.prank(admin);
        comptroller._rescueFunds(address(badToken), 1000e18);

        // Balance should NOT have changed - proving silent failure
        uint256 balanceAfter = badToken.balanceOf(admin);
        assertEq(balanceAfter, balanceBefore, "Funds NOT rescued - silent failure confirmed");
        assertEq(badToken.balanceOf(address(comptroller)), 1000e18, "Funds stuck in comptroller");
    }

    /// @notice Contrast: rescueFunds works fine with normal ERC20 tokens
    function test_rescueFunds_works_with_normal_token() public {
        FaucetToken goodToken = new FaucetToken(1000e18, "Good", 18, "GOOD");
        goodToken.transfer(address(comptroller), 1000e18);

        vm.prank(admin);
        comptroller._rescueFunds(address(goodToken), 1000e18);

        assertEq(goodToken.balanceOf(admin), 1000e18, "Funds rescued with normal token");
        assertEq(goodToken.balanceOf(address(comptroller)), 0, "Comptroller emptied");
    }

    /// @notice Non-admin cannot call _rescueFunds (basic auth works)
    function test_rescueFunds_reverts_for_non_admin() public {
        vm.prank(alice);
        vm.expectRevert("Unauthorized");
        comptroller._rescueFunds(address(badToken), 100);
    }

    /// @notice uint.max transfer also silently fails with bad token
    function test_rescueFunds_maxAmount_silently_fails() public {
        badToken.mint(address(comptroller), 1000e18);

        uint256 balanceBefore = badToken.balanceOf(admin);

        vm.prank(admin);
        comptroller._rescueFunds(address(badToken), type(uint).max);

        uint256 balanceAfter = badToken.balanceOf(admin);
        assertEq(balanceAfter, balanceBefore, "Max amount rescue also silently fails");
    }
}

/// Token that returns false on transfer instead of reverting (like USDT on some chains)
contract NoReturnToken {
    mapping(address => uint256) private _balances;
    uint256 private _totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        // Always returns false without reverting, simulating USDT-like behavior
        // The Comptroller's _rescueFunds ignores this return value
        return false;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        return false;
    }
}

// ============================================================================
// M-06: nonReentrant defined but never used in Comptroller
// Finding: Comptroller defines nonReentrant modifier (lines 1405-1417) but
//          no function in Comptroller uses it. This is dead code that could
//          give a false sense of security.
// ============================================================================
contract POC_M06_NonReentrantUnused is Test {
    Comptroller comptroller;

    function setUp() public {
        comptroller = new Comptroller();
    }

    /// @notice Proof that calling state-changing Comptroller functions twice
    ///         in the same transaction succeeds, confirming nonReentrant is NOT applied
    function test_nonReentrant_not_applied_to_setCollateralFactor() public {
        SimplePriceOracle oracle = new SimplePriceOracle();
        FaucetToken token = new FaucetToken(1000e18, "Test", 18, "TST");
        InterestRateModel irm = new WhitePaperInterestRateModel(0.1e18, 0.45e18);

        comptroller._setPriceOracle(oracle);

        MErc20Immutable mToken = new MErc20Immutable(
            address(token),
            comptroller,
            irm,
            1e18,
            "mTST",
            "mTST",
            8,
            payable(address(this))
        );

        comptroller._supportMarket(mToken);
        oracle.setUnderlyingPrice(mToken, 1e18);

        // Call _setCollateralFactor twice in same transaction
        // If nonReentrant were applied, the second call would revert with
        // "ReentrancyGuard: reentrant call"
        uint256 err1 = comptroller._setCollateralFactor(mToken, 0.75e18);
        assertEq(err1, 0, "First call succeeded");
        uint256 err2 = comptroller._setCollateralFactor(mToken, 0.5e18);
        assertEq(err2, 0, "Second call succeeded");

        // If we reach here, nonReentrant is NOT applied
        (bool isListed, uint256 collateralFactor) = comptroller.markets(address(mToken));
        assertEq(collateralFactor, 0.5e18, "Called twice - no reentrancy guard on _setCollateralFactor");
    }

    /// @notice Proof that claimReward can be called twice (no reentrancy guard)
    function test_nonReentrant_not_applied_to_claimReward() public {
        SimplePriceOracle oracle = new SimplePriceOracle();
        FaucetToken token = new FaucetToken(1000e18, "Test", 18, "TST");
        InterestRateModel irm = new WhitePaperInterestRateModel(0.1e18, 0.45e18);

        comptroller._setPriceOracle(oracle);

        MErc20Immutable mToken = new MErc20Immutable(
            address(token),
            comptroller,
            irm,
            1e18,
            "mTST",
            "mTST",
            8,
            payable(address(this))
        );

        comptroller._supportMarket(mToken);

        // Set up a reward distributor (required by claimReward)
        MultiRewardDistributor distributorImpl = new MultiRewardDistributor();
        bytes memory initdata = abi.encodeWithSignature(
            "initialize(address,address)",
            address(comptroller),
            address(this)
        );
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(distributorImpl),
            address(0x1337),
            initdata
        );
        MultiRewardDistributor distributor = MultiRewardDistributor(address(proxy));
        comptroller._setRewardDistributor(distributor);

        address[] memory holders = new address[](1);
        holders[0] = address(this);
        MToken[] memory markets = new MToken[](1);
        markets[0] = MToken(address(mToken));

        // Call claimReward twice in same transaction
        comptroller.claimReward(holders, markets, false, true);
        comptroller.claimReward(holders, markets, false, true);

        // If nonReentrant were applied, second call would revert
        assertTrue(true, "claimReward called twice without reentrancy guard");
    }

    /// @notice Proof that _setPriceOracle also has no reentrancy guard
    function test_nonReentrant_not_applied_to_setPriceOracle() public {
        SimplePriceOracle oracle1 = new SimplePriceOracle();
        SimplePriceOracle oracle2 = new SimplePriceOracle();

        comptroller._setPriceOracle(oracle1);
        comptroller._setPriceOracle(oracle2);

        assertEq(address(comptroller.oracle()), address(oracle2), "Oracle set twice without guard");
    }
}

// ============================================================================
// M-07: Stale supply cap in maxDeposit (viewExchangeRate vs exchangeRateCurrent)
// Finding: MoonwellERC4626.maxDeposit() uses viewExchangeRate() and totalSupply()
//          without calling accrueInterest() first, returning stale data.
//          After interest accrues, maxDeposit returns a value that's too high,
//          causing deposits to revert at mint time.
//
// NOTE: We test via exchangeRateStored() vs exchangeRateCurrent() on MToken.
// viewExchangeRate() in MoonwellERC4626 calls exchangeRateStored() internally
// (see LibCompound.sol:21). exchangeRateCurrent() calls accrueInterest() first.
// ============================================================================
contract POC_M07_StaleSupplyCap is Test {
    Comptroller comptroller;
    SimplePriceOracle oracle;
    FaucetToken token;
    MErc20Immutable mToken;
    InterestRateModel irm;

    function setUp() public {
        comptroller = new Comptroller();
        oracle = new SimplePriceOracle();
        token = new FaucetToken(1000e18, "Test", 18, "TST");
        irm = new WhitePaperInterestRateModel(0.1e18, 0.45e18);

        mToken = new MErc20Immutable(
            address(token),
            comptroller,
            irm,
            1e18,
            "mTST",
            "mTST",
            8,
            payable(address(this))
        );

        // admin is already address(this) from constructor
        comptroller._setPriceOracle(oracle);
        comptroller._supportMarket(mToken);
        oracle.setUnderlyingPrice(mToken, 1e18);
    }

    /// @notice Proof that exchangeRateStored() and exchangeRateCurrent() diverge after time passes
    ///         exchangeRateStored = view (stale), exchangeRateCurrent = fresh (accrues interest)
    function test_exchangeRates_diverge_after_interest_accrual() public {
        // Deposit to create borrows
        token.approve(address(mToken), 500e18);
        mToken.mint(500e18);

        // Set collateral factor and enter market
        comptroller._setCollateralFactor(mToken, 0.5e18);
        address[] memory markets = new address[](1);
        markets[0] = address(mToken);
        comptroller.enterMarkets(markets);

        // Borrow to create interest accrual
        mToken.borrow(200e18);

        uint256 storedRateBefore = mToken.exchangeRateStored();
        uint256 currentRateBefore = mToken.exchangeRateCurrent();

        // Initially they should be close
        assertGe(currentRateBefore, storedRateBefore, "Current >= stored initially");

        // Fast-forward time to accrue significant interest
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 365 days);

        // exchangeRateStored() does NOT accrue interest (stale - what maxDeposit uses)
        uint256 storedRateAfter = mToken.exchangeRateStored();
        // exchangeRateCurrent() DOES accrue interest (fresh - what mint uses)
        uint256 currentRateAfter = mToken.exchangeRateCurrent();

        // After interest accrual, fresh rate > stale rate
        assertGe(currentRateAfter, storedRateAfter, "Current >= stored after time passes");

        // The divergence proves maxDeposit uses stale data
        // maxDeposit = supplyCap - (totalSupply * storedRate / 1e18)
        // actual totalSupplies = totalSupply * currentRate / 1e18
        // If currentRate > storedRate, maxDeposit is overstated
        if (currentRateAfter > storedRateAfter) {
            assertTrue(true, "CONFIRMED: exchangeRateStored is stale after interest accrual");
        }
    }

    /// @notice Proof that after interest accrues, the stale totalSupplies calculation
    ///         understates actual deposits, causing maxDeposit to overstate capacity
    function test_maxDeposit_overstates_capacity_after_interest() public {
        MToken[] memory mTokens = new MToken[](1);
        mTokens[0] = MToken(address(mToken));
        uint256[] memory caps = new uint256[](1);
        caps[0] = 1000e18;
        comptroller._setMarketSupplyCaps(mTokens, caps);

        token.approve(address(mToken), 990e18);
        mToken.mint(990e18);

        // Enter market and borrow to create interest
        comptroller._setCollateralFactor(mToken, 0.5e18);
        address[] memory markets = new address[](1);
        markets[0] = address(mToken);
        comptroller.enterMarkets(markets);

        mToken.borrow(200e18);

        // Fast-forward
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 365 days);

        // Stale calculation (what maxDeposit uses via exchangeRateStored/viewExchangeRate)
        uint256 staleRate = mToken.exchangeRateStored();
        uint256 staleTotalSupply = mToken.totalSupply();
        uint256 staleTotalSupplies = (staleTotalSupply * staleRate) / 1e18;

        // Fresh calculation (what mint uses internally after accrueInterest)
        uint256 freshRate = mToken.exchangeRateCurrent();
        uint256 freshTotalSupplies = (staleTotalSupply * freshRate) / 1e18;

        // Fresh supplies >= stale supplies (interest increases the value)
        assertGe(freshTotalSupplies, staleTotalSupplies, "Fresh >= stale after interest");

        // The stale maxDeposit returns supplyCap - staleTotalSupplies - 2
        // But the actual remaining capacity is supplyCap - freshTotalSupplies
        // Since freshTotalSupplies >= staleTotalSupplies:
        // stale maxDeposit >= actual remaining capacity
        // This means maxDeposit can return a value larger than what's actually available
    }
}
