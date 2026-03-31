// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {console2} from "forge-std/console2.sol";

import {Scribe} from "src/Scribe.sol";
import {IScribe} from "src/IScribe.sol";

import {LibSecp256k1} from "src/libs/LibSecp256k1.sol";
import {LibFeed} from "script/libs/LibFeed.sol";
import {IToll} from "chronicle-std/toll/IToll.sol";

import {Test} from "forge-std/Test.sol";

/// @title PoC: Oracle cannot represent zero price due to val=0 sentinel
/// @notice Demonstrates that poke(val=0) succeeds but read() reverts,
///         making zero price indistinguishable from "never initialized".
contract POC_ZeroSentinel is Test {
    using LibSecp256k1 for LibSecp256k1.Point;
    using LibFeed for LibFeed.Feed;
    using LibFeed for LibFeed.Feed[];

    Scribe private scribe;
    LibFeed.Feed[] private feeds;

    function setUp() public {
        scribe = new Scribe(address(this), "ETH/USD");
        IToll(address(scribe)).kiss(address(this));
        feeds = _liftFeeds(scribe.bar());
    }

    function test_zero_price_poke_succeeds_but_read_reverts() public {
        // Step 1: Normal poke with val=1000
        IScribe.PokeData memory pokeData1;
        pokeData1.val = 1000;
        pokeData1.age = uint32(block.timestamp);
        IScribe.SchnorrData memory schnorr1 =
            feeds.signSchnorr(scribe.constructPokeMessage(pokeData1));
        scribe.poke(pokeData1, schnorr1);

        assertEq(scribe.read(), 1000);
        console2.log("Step 1: Normal poke OK, read() = 1000");

        // Step 2: Poke with val=0 (zero price - e.g., token death)
        // Advance time so age is not stale
        vm.warp(1680220900); // 100 seconds later
        IScribe.PokeData memory pokeData2;
        pokeData2.val = 0; // zero price
        pokeData2.age = 1680220900;
        IScribe.SchnorrData memory schnorr2 =
            feeds.signSchnorr(scribe.constructPokeMessage(pokeData2));
        scribe.poke(pokeData2, schnorr2);

        console2.log("Step 2: poke(val=0) SUCCEEDED - zero price stored");

        // Step 3: read() REVERTS - val=0 is sentinel for "not initialized"
        vm.expectRevert();
        scribe.read();
        console2.log("Step 3: read() REVERTS - cannot distinguish zero price from uninitialized");

        // Step 4: tryRead() returns (false, 0)
        (bool ok, uint val) = scribe.tryRead();
        assertFalse(ok);
        assertEq(val, 0);
        console2.log("Step 4: tryRead() returns (false, 0)");

        // Step 5: peek() returns (0, false)
        (uint peekVal, bool isValid) = scribe.peek();
        assertEq(peekVal, 0);
        assertFalse(isValid);
        console2.log("Step 5: peek() returns (0, false)");

        // Step 6: readWithAge() also reverts
        vm.expectRevert();
        scribe.readWithAge();
        console2.log("Step 6: readWithAge() also REVERTS");

        console2.log("PoC PASSED: Zero price = uninitialized, no way to report legit $0");
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
                scribe.lift(
                    feed.pubKey,
                    feed.signECDSA(scribe.feedRegistrationMessage())
                );
            }
            privKey++;
        }
        return feeds_;
    }
}
