// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.22;

import { console2 } from "forge-std/src/console2.sol";
import { Test } from "forge-std/src/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC165, ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { ISablierComptroller } from "@sablier/evm-utils/src/interfaces/ISablierComptroller.sol";
import { SablierLockup } from "../../src/SablierLockup.sol";
import { ISablierLockupRecipient } from "../../src/interfaces/ISablierLockupRecipient.sol";
import { Lockup } from "../../src/types/Lockup.sol";
import { LockupLinear } from "../../src/types/LockupLinear.sol";

// ============================================================================
// Mocks
// ============================================================================

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") { }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockComptroller is ISablierComptroller {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ISablierComptroller).interfaceId
            || interfaceId == 0x01ffc9a7 // ERC165
            || interfaceId == 0x65443910; // MINIMAL_INTERFACE_ID
    }
    function MINIMAL_INTERFACE_ID() external pure returns (bytes4) {
        return ISablierComptroller.calculateMinFeeWeiFor.selector
            ^ ISablierComptroller.convertUSDFeeToWei.selector
            ^ ISablierComptroller.execute.selector
            ^ ISablierComptroller.getMinFeeUSDFor.selector;
    }
    function calculateMinFeeWei(ISablierComptroller.Protocol) external pure returns (uint256) { return 0; }
    function calculateMinFeeWeiFor(ISablierComptroller.Protocol, address) external pure returns (uint256) { return 0; }
    function convertUSDFeeToWei(uint256) external pure returns (uint256) { return 0; }
    function getMinFeeUSD(ISablierComptroller.Protocol) external pure returns (uint256) { return 0; }
    function getMinFeeUSDFor(ISablierComptroller.Protocol, address) external pure returns (uint256) { return 0; }
    function VERSION() external pure returns (string memory) { return "v1.0"; }
    function MAX_FEE_USD() external pure returns (uint256) { return 100e8; }
    function attestor() external pure returns (address) { return address(0); }
    function oracle() external pure returns (address) { return address(0); }
    function ATTESTOR_MANAGER_ROLE() external pure returns (bytes32) { return bytes32(0); }
    function FEE_COLLECTOR_ROLE() external pure returns (bytes32) { return bytes32(0); }
    function FEE_MANAGEMENT_ROLE() external pure returns (bytes32) { return bytes32(0); }
    function hasRole(bytes32, address) external pure returns (bool) { return true; }
    function hasRoleOrIsAdmin(bytes32, address) external pure returns (bool) { return true; }
    function admin() external view returns (address) { return address(this); }
    function transferAdmin(address) external pure { }
    function acceptAdmin() external pure { }
    function renounceAdmin() external pure { }
    function getRoleAdmin(bytes32) external pure returns (bytes32) { return bytes32(0); }
    function grantRole(bytes32, address) external pure { }
    function revokeRole(bytes32, address) external pure { }
    function renounceRole(bytes32) external pure { }
    function disableCustomFeeUSDFor(ISablierComptroller.Protocol, address) external pure { }
    function execute(address, bytes calldata) external pure returns (bytes memory) { return ""; }
    function lowerMinFeeUSDForCampaign(address, uint256) external pure { }
    function setAttestor(address) external pure { }
    function setAttestorForCampaign(address, address) external pure { }
    function setCustomFeeUSDFor(ISablierComptroller.Protocol, address, uint256) external pure { }
    function setMinFeeUSD(ISablierComptroller.Protocol, uint256) external pure { }
    function setOracle(address) external pure { }
    function transferFees(address[] calldata, address) external pure { }
    function withdrawERC20Token(IERC20, address) external pure { }
    function proxiableUUID() external pure returns (bytes32) { return bytes32(0); }
    function upgradeToAndCall(address, bytes calldata) external pure { }

    function allowToHookOnLockup(address lockup, address recipient_) external {
        SablierLockup(lockup).allowToHook(recipient_);
    }

    receive() external payable { }
}

contract MockNFTDescriptor {
    function tokenURI(uint256) external pure returns (string memory) { return ""; }
}

contract RecipientRevertCancel is ISablierLockupRecipient, ERC165 {
    bool public shouldRevert;

    function setShouldRevert(bool value) external { shouldRevert = value; }

    function supportsInterface(bytes4 interfaceId) public view virtual override(IERC165, ERC165) returns (bool) {
        return interfaceId == type(ISablierLockupRecipient).interfaceId;
    }

    function onSablierLockupCancel(uint256, address, uint128, uint128) external view override returns (bytes4) {
        if (shouldRevert) { revert("Recipient hook reverted"); }
        return ISablierLockupRecipient.onSablierLockupCancel.selector;
    }

    function onSablierLockupWithdraw(uint256, address, address, uint128) external pure override returns (bytes4) {
        return ISablierLockupRecipient.onSablierLockupWithdraw.selector;
    }
}

// ============================================================================
// Test Contract
// ============================================================================

contract FindingVerification is Test {
    MockERC20 token;
    MockComptroller comptroller;
    MockNFTDescriptor nftDescriptor;
    SablierLockup lockup;
    RecipientRevertCancel revertRecipient;

    address sender;
    address recipient;

    function setUp() public {
        token = new MockERC20();
        comptroller = new MockComptroller();
        nftDescriptor = new MockNFTDescriptor();
        revertRecipient = new RecipientRevertCancel();

        lockup = new SablierLockup(address(comptroller), address(nftDescriptor));

        sender = address(this);
        recipient = address(revertRecipient);

        token.mint(sender, 10_000e18);
        token.approve(address(lockup), type(uint256).max);

        comptroller.allowToHookOnLockup(address(lockup), recipient);
    }

    // =========================================================================
    // F-01: SablierLockup Cancel reverts when hook recipient malfunction
    // =========================================================================

    function test_F01_cancel_succeeds_when_hook_works() public {
        uint256 streamId = _createCancelableStream();
        vm.warp(block.timestamp + 100);

        revertRecipient.setShouldRevert(false);
        lockup.cancel(streamId);

        assertTrue(lockup.wasCanceled(streamId), "Stream should be canceled");
    }

    function test_F01_cancel_reverts_when_hook_reverts() public {
        uint256 streamId = _createCancelableStream();
        vm.warp(block.timestamp + 100);

        revertRecipient.setShouldRevert(true);

        vm.expectRevert("Recipient hook reverted");
        lockup.cancel(streamId);
    }

    function test_F01_stream_not_canceled_after_hook_revert() public {
        uint256 streamId = _createCancelableStream();
        vm.warp(block.timestamp + 100);

        revertRecipient.setShouldRevert(true);
        vm.expectRevert("Recipient hook reverted");
        lockup.cancel(streamId);

        // After revert, state is unchanged
        assertFalse(lockup.wasCanceled(streamId), "Stream should not be canceled");
        assertTrue(lockup.isCancelable(streamId), "Stream should still be cancelable");
    }

    function _createCancelableStream() internal returns (uint256) {
        return lockup.createWithDurationsLL(
            Lockup.CreateWithDurations({
                sender: sender,
                recipient: recipient,
                depositAmount: 10_000e18,
                token: IERC20(address(token)),
                cancelable: true,
                transferable: true,
                shape: ""
            }),
            LockupLinear.UnlockAmounts({ start: 0, cliff: 0 }),
            1 days,
            LockupLinear.Durations({ cliff: 0, total: 365 days })
        );
    }
}
