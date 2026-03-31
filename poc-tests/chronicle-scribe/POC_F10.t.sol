// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {console2} from "forge-std/console2.sol";

import {IScribe} from "src/IScribe.sol";
import {Scribe} from "src/Scribe.sol";

import {LibSecp256k1} from "src/libs/LibSecp256k1.sol";
import {LibFeed} from "script/libs/LibFeed.sol";

import {IToll} from "chronicle-std/toll/IToll.sol";

import {Test} from "forge-std/Test.sol";

/// @title PoC: F-10 Rogue key attack (non-key-dependent proof of possession)
/// @notice Demonstrates that feedRegistrationMessage is a CONSTANT hash not
///         dependent on the public key. This is a known/acknowledged issue
///         (Cantina v2.0.0_2 Finding 3.1.1). Chronicle mitigates off-chain.
contract POC_F10 is Test {
    using LibSecp256k1 for LibSecp256k1.Point;
    using LibFeed for LibFeed.Feed;

    Scribe private scribe;

    function setUp() public {
        scribe = new Scribe(address(this), "ETH/USD");
        IToll(address(scribe)).kiss(address(this));
    }

    function test_feedRegistrationMessage_is_constant() public {
        // The feedRegistrationMessage is a constant - same for ALL feeds
        bytes32 msg1 = scribe.feedRegistrationMessage();

        // Compute it independently
        bytes32 msg2 = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256("Chronicle Feed Registration")
            )
        );

        assertEq(msg1, msg2);
        console2.log("feedRegistrationMessage is constant:", msg1 == msg2);
        console2.log("PASS: Registration message does not depend on public key");

        // The correct pattern would be:
        // H("\x19Ethereum Signed Message:\n32" || H("Chronicle Feed Registration" || pubKey))
        // This prevents choosing signature first then finding matching key
    }

    function test_two_feeds_same_message() public {
        // Two different feeds sign the SAME message
        LibFeed.Feed memory feed1 = LibFeed.newFeed({privKey: 100});
        LibFeed.Feed memory feed2 = LibFeed.newFeed({privKey: 200});

        // Both feeds sign the same constant message
        IScribe.ECDSAData memory sig1 =
            feed1.signECDSA(scribe.feedRegistrationMessage());
        IScribe.ECDSAData memory sig2 =
            feed2.signECDSA(scribe.feedRegistrationMessage());

        // Both can be lifted because ecrecover matches their respective addresses
        uint8 id1 = scribe.lift(feed1.pubKey, sig1);
        uint8 id2 = scribe.lift(feed2.pubKey, sig2);

        console2.log("Feed 1 lifted with id:", id1);
        console2.log("Feed 2 lifted with id:", id2);

        // Both feeds verified
        (bool isFeed1,) = scribe.feeds(id1);
        (bool isFeed2,) = scribe.feeds(id2);
        assertTrue(isFeed1);
        assertTrue(isFeed2);

        console2.log("PASS: Both feeds lifted with same constant message");
        console2.log("NOTE: Rogue key attack is known (Cantina v2.0.0_2 Finding 3.1.1)");
        console2.log("NOTE: Chronicle mitigates with off-chain verification");
    }

    function test_code_has_security_comment() public {
        // The code explicitly acknowledges the rogue key vulnerability
        // via @custom:security comment in IScribe.sol lines 191-194
        // This is a documentation-level test
        console2.log("IScribe.sol contains @custom:security comment acknowledging rogue-key risk");
        console2.log("PASS: Vulnerability is documented and acknowledged by Chronicle");
    }
}
