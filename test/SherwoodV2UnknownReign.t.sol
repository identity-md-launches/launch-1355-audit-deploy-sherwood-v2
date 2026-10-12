// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SherwoodV2Fixture} from "./helpers/SherwoodV2Fixture.sol";
import {SherwoodV2} from "src/SherwoodV2.sol";

/// The revision for finding 5643a8ad: once the cached leader of a round with more than
/// MAX_LEADER_SCAN (1,500) players is debited, #1 is "unknown" and the reign is parked on the
/// marker address(1) until settlement, where its seconds go to the round's final #1. These tests
/// cover the marker's lifecycle, the Robin Hood no-op while #1 is unknown, batched settlement, the
/// deferred Dice rescan on a board of more than MAX_CALLBACK_SCAN (12) players, and isolation of
/// the marker between rounds. The case where the final #1 was not the longest at #1 is reported
/// in .imd-findings.json rather than asserted here.
contract SherwoodV2UnknownReignTest is SherwoodV2Fixture {
    address internal constant UNKNOWN = address(1);
    uint256 internal constant BIG = 1501; // one over MAX_LEADER_SCAN
    address internal dave;

    function setUp() public override {
        super.setUp();
        dave = makeAddr("audit dave");
    }

    /// Fills the round with `n` one-point players at distinct synthetic addresses.
    function _fill(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            _buy(address(uint160(0x200000 + i)), 0.001 ether, SherwoodV2.Move.BUY);
        }
    }

    function _reignSum(address[4] memory who) internal view returns (uint256 total) {
        for (uint256 i; i < who.length; ++i) {
            total += game.reignOf(0, who[i]);
        }
    }

    // ── Marker lifecycle on a big board ────────────────────────────────────────

    function test_debitOfTheLeaderOnABigBoardParksTheReignOnTheMarker() public {
        uint256 t0 = GENESIS + 1; // setUp warps here; never cache block.timestamp across warps under via-IR
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY); // 100, #1 from t0
        _buy(bob, 0.09 ether, SherwoodV2.Move.BUY); // 90
        _fill(BIG - 2);
        assertEq(game.playerCount(0), BIG);
        assertEq(game.reignHolder(0), alice);

        vm.warp(t0 + 1 hours);
        _sell(alice, gameToken.balanceOf(alice)); // alice wiped; the cache is stale on a board too big to rescan
        assertEq(game.reignHolder(0), UNKNOWN, "reign must move to the marker, not stay on a debited cache");
        assertEq(game.reignOf(0, alice), 1 hours, "alice keeps exactly the seconds she really held #1");
        assertEq(game.leader(0), alice, "the cached leader is left stale; nothing rescanned 1,501 players");

        vm.warp(t0 + 2 hours);
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY); // 1 point, above the wiped cache, below bob
        assertEq(game.reignHolder(0), UNKNOWN, "a credit above the stale cache must not start a real reign");
        assertEq(game.leader(0), carol, "the cache moves to the credited player even while stale");
        assertEq(game.reignOf(0, carol), 0);
        assertEq(game.reignOf(0, bob), 0);
        assertEq(game.reignOf(0, UNKNOWN), 1 hours);
        assertEq(game.reignOf(0, alice), 1 hours);

        // The marker's running reign is capped at the round's end like any other.
        vm.warp(game.roundEnd(0) + 5 hours);
        assertEq(game.reignOf(0, UNKNOWN), game.roundEnd(0) - (t0 + 1 hours));
        assertEq(_reignSum([alice, bob, carol, UNKNOWN]), game.roundEnd(0) - t0, "reign seconds must not overlap");
    }

    function test_unknownSecondsGoToTheFinalLeaderWhoReallyHeldFirstPlace() public {
        uint256 t0 = GENESIS + 1; // setUp warps here; never cache block.timestamp across warps under via-IR
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY); // 100
        _buy(bob, 0.09 ether, SherwoodV2.Move.BUY); // 90: #1 for the rest of the round once alice sells
        _fill(BIG - 2);
        vm.warp(t0 + 1 hours);
        _sell(alice, gameToken.balanceOf(alice));
        vm.warp(t0 + 2 hours);
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY);

        _seed(0, 10 ether);
        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        while (!game.settle(0, 400)) {}

        (bool settled, address[3] memory top,,,, address king, uint256 kingReign, uint256 kingPrize,) = game.result(0);
        assertTrue(settled);
        assertEq(top[0], bob);
        assertEq(king, bob, "bob held #1 from the sell to the end and must be King");
        uint256 markerSeconds = game.roundEnd(0) - (t0 + 1 hours);
        assertEq(kingReign, markerSeconds, "the marker's seconds count for the final #1");
        assertEq(game.reignOf(0, alice), 1 hours);
        assertEq(game.reignOf(0, UNKNOWN), markerSeconds);
        assertGt(kingPrize, 0);
        assertEq(game.kingOfTheHill(0), bob);

        // bob claims both #1 and King; nothing of the marker's is ever payable to address(1).
        uint256 before = bob.balance;
        vm.prank(bob);
        game.claim(0);
        (,,, uint256[3] memory prizes,,,,,) = game.result(0);
        assertEq(bob.balance - before, prizes[0] + kingPrize);
        assertEq(game.heldToClaim(0, UNKNOWN), 0);
        vm.prank(UNKNOWN);
        vm.expectRevert(SherwoodV2.NothingToClaim.selector);
        game.claim(0);
    }

    function test_longerRealReignStillBeatsTheMarkerAtSettlement() public {
        uint256 t0 = GENESIS + 1; // setUp warps here; never cache block.timestamp across warps under via-IR
        _fill(BIG - 2);
        _buy(bob, 0.05 ether, SherwoodV2.Move.BUY); // 50
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY); // 100, #1 from t0, and the previous player
        assertEq(game.reignHolder(0), alice);

        vm.warp(t0 + 15 hours);
        // A 10-point Steal of #1 by the next player takes 22% of alice's 100: bob (82) passes alice
        // (78) only through the debit, so the cache goes stale on a board too big to rescan.
        _buy(bob, 0.01 ether, SherwoodV2.Move.STEAL);
        assertEq(game.points(0, alice), 78);
        assertEq(game.points(0, bob), 82);
        assertEq(game.reignHolder(0), UNKNOWN);
        assertEq(game.reignOf(0, alice), 15 hours);

        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        while (!game.settle(0, 500)) {}
        (, address[3] memory top,,,, address king, uint256 kingReign,,) = game.result(0);
        assertEq(top[0], bob);
        assertEq(top[1], alice);
        assertEq(king, alice, "15 hours at #1 beats the 5 hours parked on the marker");
        assertEq(kingReign, 15 hours);
        assertEq(game.reignOf(0, UNKNOWN), game.roundEnd(0) - (t0 + 15 hours));
    }

    function test_markerSecondsOnlyCrownOnTheLastSettlementBatch() public {
        uint256 t0 = GENESIS + 1; // setUp warps here; never cache block.timestamp across warps under via-IR
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.09 ether, SherwoodV2.Move.BUY);
        _fill(BIG - 2);
        vm.warp(t0 + 1 hours);
        _sell(alice, gameToken.balanceOf(alice));
        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());

        assertFalse(game.settle(0, 1000));
        (bool settled,,,,, address king, uint256 kingReign,,) = game.result(0);
        assertFalse(settled);
        // Before the last batch the only real reign is alice's hour; the marker is not yet applied.
        assertEq(king, alice);
        assertEq(kingReign, 1 hours);

        assertFalse(game.settle(0, 500)); // 1,500 of 1,501 scanned: still not the last batch
        (settled,,,,, king, kingReign,,) = game.result(0);
        assertFalse(settled);
        assertEq(king, alice);

        assertTrue(game.settle(0, 500));
        (settled,,,,, king, kingReign,,) = game.result(0);
        assertTrue(settled);
        assertEq(king, bob, "crowned once, on the batch that reaches the end of the board");
        assertEq(kingReign, game.roundEnd(0) - (t0 + 1 hours));
        vm.expectRevert(SherwoodV2.AlreadySettled.selector);
        game.settle(0, 500);
    }

    function test_settlementOfABigBoardWithNobodyAboveZeroHasNoKing() public {
        // Every player ends at or below zero: the marker's seconds have no #1 to go to.
        uint256 t0 = GENESIS + 1; // setUp warps here; never cache block.timestamp across warps under via-IR
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY);
        _fill(BIG - 1);
        vm.warp(t0 + 1 hours);
        _sell(alice, gameToken.balanceOf(alice));
        assertEq(game.reignHolder(0), UNKNOWN);
        for (uint256 i; i < BIG - 1; ++i) {
            address filler = address(uint160(0x200000 + i));
            _sell(filler, gameToken.balanceOf(filler));
        }
        _seed(0, 1 ether);
        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        while (!game.settle(0, 400)) {}
        (bool settled, address[3] memory top,,,, address king, uint256 kingReign, uint256 kingPrize,) = game.result(0);
        assertTrue(settled);
        assertEq(top[0], address(0));
        // Alice held #1 for an hour before selling: she is King by seconds, with a forfeited prize.
        assertEq(king, alice);
        assertEq(kingReign, 1 hours);
        assertEq(kingPrize, 0, "sold every token bought: the King's share is forfeited to the rollover");
        // Nothing awarded: everything but the two burns rolls into the live round.
        assertEq(game.pot(game.currentRound()), game.pot(0) - (game.pot(0) * 1700) / 10_000);
    }

    // ── Robin Hood while #1 is unknown ─────────────────────────────────────────

    function test_robinHoodDoesNothingAndKeepsItsChargeWhileTheLeaderIsUnknown() public {
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY); // 100
        _buy(bob, 0.09 ether, SherwoodV2.Move.BUY); // 90
        _fill(BIG - 2);
        assertEq(game.robinsLeft(dave), 3);

        // Known leader: the move works and spends a charge (12.3% of alice's 100 at a 10-point buy).
        _buy(dave, 0.01 ether, SherwoodV2.Move.ROBIN_HOOD);
        assertEq(game.points(0, alice), 88);
        assertEq(game.robinsLeft(dave), 2);
        assertEq(game.points(0, dave), 10);

        _sell(alice, gameToken.balanceOf(alice)); // leader debited: #1 unknown for the rest of the round
        assertEq(game.reignHolder(0), UNKNOWN);

        vm.expectEmit(true, true, true, true, address(game));
        emit SherwoodV2.Played(0, dave, SherwoodV2.Move.ROBIN_HOOD, 0.01 ether, 10, address(0), 0);
        _buy(dave, 0.01 ether, SherwoodV2.Move.ROBIN_HOOD);
        assertEq(game.points(0, dave), 20, "the buy itself still scores");
        assertEq(game.robinsLeft(dave), 2, "no charge is spent on a move that did nothing");
        assertEq(game.points(0, bob), 90, "nobody is robbed off a stale cache");
        assertEq(game.points(0, alice), 0);
        assertEq(game.reignHolder(0), UNKNOWN);
    }

    function test_robinHoodByTheStaleCachedLeaderAlsoDoesNothing() public {
        _buy(bob, 0.09 ether, SherwoodV2.Move.BUY);
        _fill(BIG - 2);
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY); // cached leader and last player
        vm.warp(block.timestamp + 10 minutes);
        _buy(bob, 0.001 ether, SherwoodV2.Move.STEAL); // 20% of alice's 100
        assertEq(game.points(0, alice), 80);
        assertEq(game.reignHolder(0), UNKNOWN);
        uint256 robins = game.robinsLeft(alice);
        _buy(alice, 0.001 ether, SherwoodV2.Move.ROBIN_HOOD);
        assertEq(game.points(0, alice), 81);
        assertEq(game.points(0, bob), 111);
        assertEq(game.robinsLeft(alice), robins);
    }

    // ── Deferred rescan after a Dice callback on a board of more than 12 players ──

    function test_deferredRescanGapIsCreditedToTheFinalLeaderAtSettlement() public {
        uint256 t0 = GENESIS + 1; // setUp warps here; never cache block.timestamp across warps under via-IR
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY); // 50, #1 from t0
        _fill(11);
        _buy(bob, 0.045 ether, SherwoodV2.Move.BUY); // 45; 13 players now
        assertEq(game.playerCount(0), 13);

        uint256 t1 = t0 + 60;
        vm.warp(t1);
        _buy(alice, 0.01 ether, SherwoodV2.Move.FLIP); // stake 10, previous = bob
        assertEq(game.pendingFlips(0), 1);
        assertEq(game.reignHolder(0), alice);
        vm.cool(address(game));
        assertTrue(dice.reveal(1, bytes32(uint256(1))), "callback must fit the Dice gas limit");
        assertEq(game.points(0, alice), 40);
        assertEq(game.points(0, bob), 55);
        assertEq(game.reignHolder(0), UNKNOWN, "13 players is too many to rescan in the callback");
        assertEq(game.reignOf(0, alice), 60);

        uint256 t2 = t1 + 300;
        vm.warp(t2);
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY); // rescans 14 players with the swapper's gas
        assertEq(game.reignHolder(0), bob);
        assertEq(game.leader(0), bob);
        assertEq(game.reignOf(0, UNKNOWN), 300);
        assertEq(game.reignOf(0, bob), 0);

        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        assertTrue(game.settle(0, 100));
        (, address[3] memory top,,,, address king, uint256 kingReign,,) = game.result(0);
        assertEq(top[0], bob);
        assertEq(king, bob);
        assertEq(kingReign, game.roundEnd(0) - t1, "bob was #1 from the reveal on: the gap counts for him");
        assertEq(game.reignOf(0, alice), 60);
    }

    function test_expiredFlipOfTheLeaderRescansAndLeavesNoMarker() public {
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY);
        _fill(11);
        _buy(bob, 0.045 ether, SherwoodV2.Move.BUY);
        _buy(alice, 0.01 ether, SherwoodV2.Move.FLIP);
        vm.warp(block.timestamp + game.FLIP_TIMEOUT());
        game.expireFlip(1); // scores as a buy: alice 60, no debit, no stale cache
        assertEq(game.points(0, alice), 60);
        assertEq(game.reignHolder(0), alice);
        assertEq(game.reignOf(0, UNKNOWN), 0);
    }

    // ── Isolation ──────────────────────────────────────────────────────────────

    function test_markerStateDoesNotLeakIntoTheNextRound() public {
        uint256 t0 = GENESIS + 1; // setUp warps here; never cache block.timestamp across warps under via-IR
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.09 ether, SherwoodV2.Move.BUY);
        _fill(BIG - 2);
        vm.warp(t0 + 1 hours);
        _sell(alice, gameToken.balanceOf(alice));
        assertEq(game.reignHolder(0), UNKNOWN);

        vm.warp(game.roundEnd(0) + 1);
        _buy(carol, 0.002 ether, SherwoodV2.Move.BUY);
        assertEq(game.reignHolder(1), carol, "round 1 starts with a known leader");
        assertEq(game.reignOf(1, UNKNOWN), 0);
        assertEq(game.leader(1), carol);
        assertEq(game.reignHolder(0), UNKNOWN, "round 0's marker stays until settlement");
        vm.warp(game.roundEnd(1) + game.SETTLE_DELAY());
        while (!game.settle(0, 400)) {}
        assertTrue(game.settle(1, 10));
        (, address[3] memory top,,,, address king, uint256 kingReign,,) = game.result(1);
        assertEq(top[0], carol);
        assertEq(king, carol);
        assertEq(kingReign, game.ROUND_LENGTH() - 1);
        (,,,,, king, kingReign,,) = game.result(0);
        assertEq(king, bob);
        assertEq(kingReign, game.roundEnd(0) - (t0 + 1 hours));
    }

    function test_robinHoodStillWorksOnABoardOfExactlyMaxLeaderScanAfterADebit() public {
        // 1,500 players is the largest board a swap still rescans: a debited cache is repaired in place.
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.09 ether, SherwoodV2.Move.BUY);
        _fill(BIG - 3);
        assertEq(game.playerCount(0), 1500);
        vm.warp(block.timestamp + 1 hours);
        _sell(alice, gameToken.balanceOf(alice));
        assertEq(game.reignHolder(0), bob, "a 1,500-player board is rescanned inside the sell");
        assertEq(game.leader(0), bob);
        _buy(dave, 0.01 ether, SherwoodV2.Move.ROBIN_HOOD);
        assertEq(game.points(0, bob), 79); // 90 less 12.3% of 90 at a 10-point buy
        assertEq(game.robinsLeft(dave), 2);
    }
}
