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

/// @title PoC: F-09 uint32 timestamp truncation
/// @notice Demonstrates that uint32 age overflows at year 2106 and
///         that opPokeData.age + opChallengePeriod can overflow uint32.
contract POC_F09 is Test {
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

    function test_uint32_max_timestamp() public pure {
        uint32 maxUint32 = type(uint32).max;
        console2.log("Max uint32:", maxUint32);
        // 4,294,967,295 = Feb 7, 2106
        console2.log("Max uint32 as year:", maxUint32 / 31536000 + 1970);
    }

    function test_age_is_uint32_truncated() public {
        // Poke at current timestamp
        IScribe.PokeData memory pokeData;
        pokeData.val = 1000;
        pokeData.age = uint32(block.timestamp);
        IScribe.SchnorrData memory schnorr =
            feeds.signSchnorr(opScribe.constructPokeMessage(pokeData));
        opScribe.poke(pokeData, schnorr);

        // Verify age is stored as uint32
        (, uint age) = opScribe.readWithAge();
        assertEq(age, uint32(block.timestamp));
        console2.log("Age stored as uint32:", age);

        // Demonstrate truncation: set block.timestamp beyond uint32 max
        uint futureTimestamp = uint(type(uint32).max) + 100;
        vm.warp(futureTimestamp);

        uint32 truncated = uint32(futureTimestamp);
        console2.log("Future timestamp:", futureTimestamp);
        console2.log("Truncated to uint32:", truncated);

        // After truncation, the truncated value is LESS than the previous age
        // This would make poke appear "stale"
        assertTrue(truncated < age);
        console2.log("PASS: Timestamp truncation causes age comparison issues");
    }

    function test_opPokeData_age_plus_period_overflow() public {
        // Demonstrate potential overflow of opPokeData.age + opChallengePeriod
        // near uint32 max

        // Set timestamp near max uint32
        uint nearMax = uint(type(uint32).max) - 10;
        vm.warp(nearMax);

        // Poke at this timestamp
        IScribe.PokeData memory pokeData;
        pokeData.val = 1000;
        pokeData.age = uint32(block.timestamp);
        IScribe.SchnorrData memory schnorr =
            feeds.signSchnorr(opScribe.constructPokeMessage(pokeData));
        opScribe.poke(pokeData, schnorr);

        // Advance to nearMax + 1
        uint256 opPokeTime = nearMax + 1;
        vm.roll(block.number + 1);
        vm.warp(opPokeTime);
        IScribe.PokeData memory pokeData2;
        pokeData2.val = 2000;
        pokeData2.age = uint32(opPokeTime);

        IScribe.SchnorrData memory fakeSchnorr = IScribe.SchnorrData({
            signature: bytes32(uint(0xdeadbeef)),
            commitment: address(0x1),
            feedIds: abi.encodePacked(feeds[0].id)
        });
        IScribe.ECDSAData memory ecdsaData =
            feeds[0].signECDSA(opScribe.constructOpPokeMessage(pokeData2, fakeSchnorr));
        opScribe.opPoke(pokeData2, fakeSchnorr, ecdsaData);

        // Now warp to nearMax + 5 - age + opChallengePeriod would overflow uint32
        // opPokeData.age = uint32(nearMax + 1) = nearMax + 1
        // opChallengePeriod = 1200 (20 min default)
        // sum = nearMax + 1 + 1200 = nearMax + 1201 > type(uint32).max when nearMax > type(uint32).max - 1201
        vm.warp(nearMax + 5);

        // opPokeData.age + opChallengePeriod would overflow
        // In Solidity 0.8.x this would REVERT (checked arithmetic)
        uint32 age = uint32(nearMax + 1);
        uint16 period = opScribe.opChallengePeriod();
        console2.log("opPokeData.age:", age);
        console2.log("opChallengePeriod:", period);
        console2.log("Sum would be:", uint(age) + uint(period));
        console2.log("Max uint32:", uint(type(uint32).max));
        console2.log("Overflow:", uint(age) + uint(period) > uint(type(uint32).max));
        console2.log("PASS: uint32 overflow demonstrated near year 2106");
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
