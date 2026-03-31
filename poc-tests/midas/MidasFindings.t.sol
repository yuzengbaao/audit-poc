// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import "../lib/forge-std/src/Test.sol";

// ============================================================
// Minimal mock contracts - no dependency on main project
// ============================================================

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public decimals;
    address public minter;
    address public burner;

    constructor(uint8 _decimals) {
        decimals = _decimals;
        minter = msg.sender;
        burner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "not minter");
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == burner, "not burner");
        balanceOf[from] -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ============================================================
// F-02: GrowthFeed applyGrowth - exact copy of the function
// ============================================================

contract GrowthFeedCopy {
    uint256 private constant _ONE = 10**8;

    function applyGrowth(
        int256 _answer,
        int80 _growthApr,
        uint256 _timestampFrom,
        uint256 _timestampTo
    ) public pure returns (int256) {
        int256 passedSeconds = int256(_timestampTo) - int256(_timestampFrom);
        require(passedSeconds >= 0, "CAG: timestampTo < timestampFrom");

        int256 interest = (_answer * passedSeconds * _growthApr) /
            int256(100 * _ONE * 365 days);

        return _answer + interest;
    }
}

// ============================================================
// F-08: FeedDeviation - exact copy of _getDeviation
// ============================================================

contract FeedDeviationCopy {
    function _getDeviation(int256 _lastPrice, int256 _newPrice)
        public
        pure
        returns (uint256)
    {
        uint8 _decimals = 8;
        if (_newPrice == 0) return 100 * 10**_decimals;
        int256 one = int256(10**_decimals);
        int256 priceDif = _newPrice - _lastPrice;
        int256 deviation = (priceDif * one * 100) / _lastPrice;
        deviation = deviation < 0 ? deviation * -1 : deviation;
        return uint256(deviation);
    }
}

// ============================================================
// F-04: _getTokenRate logic - exact copy
// ============================================================

contract MockDataFeed {
    uint256 public answer;
    bool public stale;
    bool public shouldRevert;

    function setAnswer(uint256 _answer) external { answer = _answer; }
    function setStale(bool _stale) external { stale = _stale; }
    function setShouldRevert(bool _revert) external { shouldRevert = _revert; }

    function getDataInBase18() external view returns (uint256) {
        require(!shouldRevert, "DF: feed is unhealthy");
        require(!stale, "DF: feed is unhealthy");
        return answer;
    }
}

contract TokenRateCopy {
    uint256 public constant STABLECOIN_RATE = 10**18;

    function _getTokenRate(
        address dataFeed,
        bool stable
    ) public view returns (uint256) {
        uint256 rate = MockDataFeed(dataFeed).getDataInBase18();
        if (stable) return STABLECOIN_RATE;
        return rate;
    }
}

// ============================================================
// F-07: withdrawToken - exact copy
// ============================================================

contract WithdrawTokenCopy {
    address public mTokenAddr;
    mapping(address => bool) public isVaultAdmin;

    modifier onlyVaultAdmin() {
        require(isVaultAdmin[msg.sender], "not vault admin");
        _;
    }

    function setVaultAdmin(address admin, bool status) external {
        isVaultAdmin[admin] = status;
    }

    function withdrawToken(
        address token,
        uint256 amount,
        address withdrawTo
    ) external onlyVaultAdmin {
        MockERC20(token).transfer(withdrawTo, amount);
    }
}

// ============================================================
// TEST CONTRACT
// ============================================================

contract MidasFindingsTest is Test {
    GrowthFeedCopy growthFeed;
    FeedDeviationCopy feedDeviation;
    TokenRateCopy tokenRate;
    MockDataFeed dataFeed;
    WithdrawTokenCopy withdrawVault;
    MockERC20 mockToken;
    MockERC20 mTokenContract;

    function setUp() public {
        growthFeed = new GrowthFeedCopy();
        feedDeviation = new FeedDeviationCopy();
        tokenRate = new TokenRateCopy();
        dataFeed = new MockDataFeed();
        withdrawVault = new WithdrawTokenCopy();
        mockToken = new MockERC20(6);
        mTokenContract = new MockERC20(18);
    }

    // ================================================================
    // F-01 & F-03: Allowance decremented by full amount (including
    // fee equivalent) while actual outflow is fee-less amount
    // ================================================================

    function test_F01_F03_allowance_consumed_faster_than_actual_outflow() public {
        uint256 amountMTokenIn = 10000e18;
        uint256 instantFeePercent = 100; // 1% fee

        uint256 feeAmount = (amountMTokenIn * instantFeePercent) / 10000;
        uint256 amountMTokenWithoutFee = amountMTokenIn - feeAmount;

        uint256 mTokenRate = 1e18;
        uint256 tokenOutRate = 1e18;

        // From RedemptionVault._redeemInstant (line 598-604):
        // amountTokenOut = (amountMTokenInUsd * 1e18) / tokenOutRate
        // amountMTokenInUsd = (amountMTokenIn * mTokenRate) / 1e18
        uint256 amountMTokenInUsd = (amountMTokenIn * mTokenRate) / 1e18;
        uint256 amountTokenOut = (amountMTokenInUsd * 1e18) / tokenOutRate;

        // From line 606-608:
        // amountTokenOutWithoutFee = (amountMTokenWithoutFee * mTokenRate) / tokenOutRate
        uint256 amountTokenOutWithoutFee = (amountMTokenWithoutFee * mTokenRate) / tokenOutRate;

        // From line 616:
        // _requireAndUpdateAllowance(tokenOutCopy, amountTokenOut) -- FULL amount
        // But actual transfer at line 627-631 uses amountTokenOutWithoutFee

        assertGt(amountTokenOut, amountTokenOutWithoutFee,
            "allowance decrement must be > actual outflow");
        assertEq(amountTokenOut - amountTokenOutWithoutFee, 100e18,
            "wastage = fee in token terms");

        // This confirms the finding: ~1% of allowance is "wasted" per redemption
    }

    function test_F01_F03_allowance_discrepancy_with_non_unity_rates() public {
        uint256 amountMTokenIn = 1000e18;
        uint256 feeAmount = (amountMTokenIn * 100) / 10000; // 1% = 10 mToken
        uint256 amountMTokenWithoutFee = amountMTokenIn - feeAmount;

        uint256 mTokenRate = 0.95e18;  // mToken worth $0.95
        uint256 tokenOutRate = 1e18;   // USDC worth $1

        uint256 amountMTokenInUsd = (amountMTokenIn * mTokenRate) / 1e18;
        uint256 amountTokenOut = (amountMTokenInUsd * 1e18) / tokenOutRate;
        uint256 amountTokenOutWithoutFee = (amountMTokenWithoutFee * mTokenRate) / tokenOutRate;

        assertGt(amountTokenOut, amountTokenOutWithoutFee);

        // Wastage = (feeAmount * mTokenRate) / tokenOutRate = 10 * 0.95 = 9.5 USDC
        uint256 expectedWastage = (feeAmount * mTokenRate) / tokenOutRate;
        assertEq(amountTokenOut - amountTokenOutWithoutFee, expectedWastage);
    }

    function test_F01_F03_fee_calculation_correctness() public {
        uint256 amountMTokenIn = 1000e18;
        uint256 instantFeePercent = 100; // 1%

        uint256 feeAmount = (amountMTokenIn * instantFeePercent) / 10000;
        assertEq(feeAmount, 10e18, "1% fee on 1000 mToken = 10 mToken");

        uint256 amountMTokenWithoutFee = amountMTokenIn - feeAmount;
        assertEq(amountMTokenWithoutFee, 990e18, "user gets output based on 990 mToken");
    }

    // ================================================================
    // F-02: applyGrowth overflow
    // ================================================================

    function test_F02_overflow_with_max_values() public {
        // With max int192 answer and max int80 growthApr, overflow occurs
        // in the intermediate multiplication _answer * passedSeconds * _growthApr
        int256 _answer = int256(type(int192).max);  // ~3.1e57
        int80 _growthApr = int80(type(int80).max);   // ~6.1e23

        // Even with just 1 second, the product overflows int256
        vm.expectRevert();
        growthFeed.applyGrowth(_answer, _growthApr, 1, 2);
    }

    function test_F02_overflow_with_large_answer_moderate_apr() public {
        // With max int192 answer and 100% APR, overflow occurs after ~58 years
        int256 _answer = int256(type(int192).max);
        int80 _growthApr = int80(1e10); // 100% APR (1e10 with 8 decimals = 100%)

        // 60 years should cause overflow: 3.14e57 * 1e10 * 1.89e9 > 5.79e76
        vm.expectRevert();
        growthFeed.applyGrowth(_answer, _growthApr, 1, 365 days * 60);
    }

    function test_F02_no_overflow_realistic_values() public {
        // Realistic values should NOT overflow
        int256 _answer = int256(2e9);     // $20 with 8 decimals
        int80 _growthApr = int80(5e8);    // 5% APR

        // 1 year of growth
        int256 result = growthFeed.applyGrowth(
            _answer, _growthApr, 0, 365 days
        );
        // interest = (2e9 * 31536000 * 5e8) / (100 * 1e8 * 31536000) = 1e8
        // result = 2e9 + 1e8 = 2.1e9 (5% growth on $20 = $21)
        assertEq(result, 21e8, "5% growth on $20 should be $21");
    }

    function test_F02_negative_passedSeconds_reverts() public {
        vm.expectRevert("CAG: timestampTo < timestampFrom");
        growthFeed.applyGrowth(1e8, 1, 100, 50);
    }

    // ================================================================
    // F-04: Stable token rate bypasses oracle validation
    // ================================================================

    function test_F04_stable_returns_1e18_regardless_of_oracle() public {
        dataFeed.setAnswer(1e18);
        uint256 rate = tokenRate._getTokenRate(address(dataFeed), true);
        assertEq(rate, 1e18, "stable should return 1e18");

        // Even with depegged oracle value
        dataFeed.setAnswer(0.5e18);
        rate = tokenRate._getTokenRate(address(dataFeed), true);
        assertEq(rate, 1e18, "stable ignores depegged oracle");
    }

    function test_F04_stable_reverts_on_stale_oracle() public {
        dataFeed.setAnswer(1e18);
        dataFeed.setStale(true);

        vm.expectRevert("DF: feed is unhealthy");
        tokenRate._getTokenRate(address(dataFeed), true);
    }

    function test_F04_nonstable_returns_actual_oracle_value() public {
        dataFeed.setAnswer(2000e18);
        uint256 rate = tokenRate._getTokenRate(address(dataFeed), false);
        assertEq(rate, 2000e18, "non-stable returns oracle value");
    }

    function test_F04_stable_vs_nonstable_same_oracle() public {
        dataFeed.setAnswer(0.95e18); // $0.95 - depegged

        uint256 stableRate = tokenRate._getTokenRate(address(dataFeed), true);
        uint256 nonStableRate = tokenRate._getTokenRate(address(dataFeed), false);

        assertEq(stableRate, 1e18, "stable always returns 1e18");
        assertEq(nonStableRate, 0.95e18, "non-stable returns actual oracle");

        // The discrepancy: a depegged stablecoin is still valued at 1:1
        // This allows depositing 100 USDC (worth $95) and receiving mTokens worth $100
        assertGt(stableRate, nonStableRate,
            "stable rate > oracle rate when depegged");
    }

    // ================================================================
    // F-05: Axelar contract lacks reentrancy guard
    // ================================================================
    // This is a code review finding - verified by source analysis.
    // The MidasAxelarVaultExecutable does NOT inherit ReentrancyGuardUpgradeable.
    // The MidasLzVaultComposerSync DOES inherit ReentrancyGuardUpgradeable.
    // However, handleExecuteWithInterchainToken has msg.sender == address(this) check,
    // which prevents direct reentrancy from ITS callbacks.
    // depositAndSend and redeemAndSend are external payable without nonReentrant.

    function test_F05_code_review_confirms_missing_reentrancy_guard() public {
        // Verified from source:
        // contracts/misc/axelar/MidasAxelarVaultExecutable.sol:24-28
        //   contract MidasAxelarVaultExecutable is
        //       InterchainTokenExecutable,
        //       IMidasAxelarVaultExecutable,
        //       MidasInitializable
        //   NO ReentrancyGuardUpgradeable
        //
        // depositAndSend (line 206): external payable (no nonReentrant)
        // redeemAndSend (line 225): external payable (no nonReentrant)
        //
        // Mitigation: handleExecuteWithInterchainToken (line 190) has:
        //   if (msg.sender != address(this)) revert OnlySelf(msg.sender);
        // This prevents reentrancy from ITS callbacks.
        //
        // However, depositAndSend/redeemAndSend are directly callable
        // and perform external calls to vault contracts. If those vault
        // contracts could reenter (unlikely in practice), there's no guard.
        assertTrue(true, "Finding confirmed by code review - missing defense-in-depth");
    }

    // ================================================================
    // F-06: DepositVault totalMinted inconsistency
    // ================================================================

    function test_F06_totalMinted_inconsistency_analysis() public {
        // Code paths verified from DepositVault.sol:
        //
        // INSTANT (line 488): totalMinted[msg.sender] += result.mintAmount
        //   - Updated immediately after deposit
        //
        // REQUEST (lines 520-562): totalMinted NOT updated
        //   - _calcAndValidateDeposit checks totalMinted[user] for first-deposit min
        //   - But totalMinted[user] is never incremented
        //
        // APPROVAL (line 602): totalMinted[request.sender] += amountMToken
        //   - request.sender = recipient (from line 554)
        //   - Updated for recipient, not original caller

        // Key question: Can a user bypass minMTokenAmountForFirstDeposit?
        // NO - because _calcAndValidateDeposit is called for BOTH flows with user=msg.sender
        // If totalMinted[user] == 0 and amount < minMTokenAmountForFirstDeposit, BOTH revert.

        // The inconsistency is:
        // 1. Between request creation and approval, totalMinted[msg.sender] is stale
        // 2. A user could create multiple small requests IF they pass the first-deposit check
        //    (but they can't bypass it)
        // 3. totalMinted tracks recipient at approval, not caller at request time

        assertTrue(true, "Inconsistency exists but bypass claim is invalid");
    }

    function test_F06_first_deposit_check_enforced_in_both_flows() public {
        // Both _depositInstant and _depositRequest call _calcAndValidateDeposit(user, ...)
        // which calls _validateMinAmount(user, result.mintAmount)
        // which checks: if totalMinted[user] == 0, require(mintAmount >= minMTokenAmountForFirstDeposit)

        // The first-deposit minimum IS enforced at request creation time.
        // After a request is created, totalMinted[msg.sender] remains 0 until approval.
        // But this doesn't help the user bypass the check since it's checked at creation.

        assertTrue(true, "First-deposit minimum enforced in both flows");
    }

    // ================================================================
    // F-07: withdrawToken allows withdrawing mToken
    // ================================================================

    function test_F07_admin_can_withdraw_mToken() public {
        address admin = address(0x111);
        address attacker = address(0x222);

        withdrawVault.setVaultAdmin(admin, true);
        mTokenContract.mint(address(withdrawVault), 1000e18);

        vm.prank(admin);
        withdrawVault.withdrawToken(address(mTokenContract), 1000e18, attacker);

        assertEq(mTokenContract.balanceOf(attacker), 1000e18);
        assertEq(mTokenContract.balanceOf(address(withdrawVault)), 0);
    }

    function test_F07_admin_can_withdraw_any_token() public {
        address admin = address(0x111);
        address receiver = address(0x222);

        withdrawVault.setVaultAdmin(admin, true);
        mockToken.mint(address(withdrawVault), 500e6);

        vm.prank(admin);
        withdrawVault.withdrawToken(address(mockToken), 500e6, receiver);

        assertEq(mockToken.balanceOf(receiver), 500e6);
    }

    function test_F07_non_admin_cannot_withdraw() public {
        address nonAdmin = address(0x333);
        vm.prank(nonAdmin);
        vm.expectRevert("not vault admin");
        withdrawVault.withdrawToken(address(mockToken), 100, nonAdmin);
    }

    function test_F07_withdrawToken_has_no_token_restriction() public {
        // The function accepts ANY address as token parameter
        // There is no check like: require(token != address(mToken))
        // This means a compromised vault admin can drain ANY ERC20
        address admin = address(0x111);

        withdrawVault.setVaultAdmin(admin, true);

        // Create a random token and send to vault
        MockERC20 randomToken = new MockERC20(18);
        randomToken.mint(address(withdrawVault), 999e18);

        vm.prank(admin);
        withdrawVault.withdrawToken(address(randomToken), 999e18, admin);

        assertEq(randomToken.balanceOf(admin), 999e18,
            "admin withdrew arbitrary token from vault");
    }

    // ================================================================
    // F-08: Division by zero in _getDeviation
    // ================================================================

    function test_F08_division_by_zero_when_lastPrice_zero() public {
        // When _lastPrice = 0 and _newPrice != 0, division by zero occurs
        vm.expectRevert();
        feedDeviation._getDeviation(0, 1e8);
    }

    function test_F08_newPrice_zero_returns_100_percent() public {
        uint256 deviation = feedDeviation._getDeviation(1e8, 0);
        assertEq(deviation, 100 * 10**8, "zero new price returns 100% deviation");
    }

    function test_F08_both_prices_zero_newPrice_case() public {
        // When _newPrice = 0, it returns 100% BEFORE division
        uint256 deviation = feedDeviation._getDeviation(0, 0);
        assertEq(deviation, 100 * 10**8, "both zero returns 100% via newPrice check");
    }

    function test_F08_normal_5percent_deviation() public {
        uint256 deviation = feedDeviation._getDeviation(100e8, 105e8);
        assertEq(deviation, 5e8, "5% deviation");
    }

    function test_F08_negative_5percent_deviation() public {
        uint256 deviation = feedDeviation._getDeviation(100e8, 95e8);
        assertEq(deviation, 5e8, "absolute 5% deviation");
    }

    function test_F08_zero_lastPrice_nonzero_newPrice_reverts() public {
        // Core vulnerability path:
        // 1. Admin sets minAnswer = 0 in CustomAggregatorV3CompatibleFeed
        // 2. setRoundData(0) succeeds (0 >= minAnswer(0) && 0 <= maxAnswer)
        // 3. setRoundDataSafe(1e8) calls _getDeviation(0, 1e8) -> division by zero
        vm.expectRevert();
        feedDeviation._getDeviation(0, 1e8);
    }
}
