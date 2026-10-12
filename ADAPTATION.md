# Adaptation for the $IMD launch on Robinhood Chain (4663)

The launch deploys one contract, `src/SherwoodV2Launcher.sol:SherwoodV2Launcher`, whose constructor mines
a CREATE2 salt and deploys the `SherwoodV2` hook at an address carrying the hook flags (`0x20CC`). The
hook is `launcher.hook()`. Constructor arguments, in order: poolManager, token ($IMD), host ($PFWA),
hostHolderMin, dice, diceProvider, owner (`$owner`), genesis. The launcher already met the launch rules
as it arrived (nonpayable constructor, static argument types, 8 of at most 16 arguments, an explicit
owner argument, no call to any other contract in either constructor, no proxy, no DELEGATECALL,
CALLCODE or SELFDESTRUCT, no minting, pausing or seizing). No change was needed to it, to the game
rules or to the pot split. The changes below are the fixes for the imported audit.

## Changes

| # | File | Change | Why |
|---|---|---|---|
| 1 | `src/SherwoodV2.sol` (`_entropyCallback`, new `MAX_CALLBACK_SCAN`, `_updateReign` split into `_updateReign` + `_setReign`) | After a lost flip by the cached leader, the Dice callback no longer rescans a board of more than `MAX_CALLBACK_SCAN` (12) players. On a bigger board it closes the current reign at the reveal (holder set to nobody, time so far credited) and leaves the leader cache stale; the next play, sell or expiry rescans with its caller's gas and starts the new reign from then. Boards of up to 12 players are still rescanned inside the callback. | Audit high `490703de…` reproduced: the judge's proof test fails on the code as it arrived (callback used 207,203 gas against the 200,000 `FLIP_CALLBACK_GAS` limit with 200 players) and passes after the fix (109,369 gas). Without it the leader's lost flip was never applied and `expireFlip` refunded the stake. |
| 2 | `src/SherwoodV2.sol` (`_reflect`) | A reflected Steal or Robin Hood now charges the attacker the whole cut the move would have taken, even below zero (as a lost flip does), instead of capping it at the attacker's positive points. A move that would have taken nothing reflects nothing and leaves the shield up. | Audit low `3e2286a2…` reproduced: a fresh wallet with 1 point stripped a shield for one point, and a zero-point Steal stripped it for nothing. The README rule ("the next Steal or Robin Hood aimed at the shielded player is reflected, and the attacker pays") is kept: the shield still breaks on the first attack that it reflects, and the attacker always pays the full price. |
| 3 | `test/SherwoodV2.t.sol` | `MockDiceV2.reveal` now gives the callback exactly the gas limit the request asked for and fails if the callback fails, as Dice does; `tryReveal` reports the outcome and gas. New tests: `test_leaderLostFlipCallbackFitsDiceGasLimitOnABigBoard`, `test_leaderLostFlipRescansASmallBoardInsideTheCallback`, `test_leaderLostFlipDefersTheRescanJustPastTheBound`, `test_otherFlipOutcomesFitDiceGasLimitOnABigBoard`, `test_throwawayWalletPaysTheFullCutToBreakAShield`, `test_stealThatTakesNothingLeavesTheShieldUp`. The two tests that encoded the capped reflect (`test_reflectedStealCappedAtAttackersPoints`, `test_reflectedRobinHoodCappedAtRobbersPoints`) became `…TakesTheFullCutBelowZero` with the new expected points. | Every change is tested; every flip test now runs the callback under the real gas budget. |
| 4 | `README.md` (Sherwood v2 section) | Documents the full-price reflect and the deferred rescan after a leader's lost flip. | Keeps the requester's notes in step with the rules. |

## Audit findings

| Finding | Status |
|---|---|
| High `490703de…` Dice callback runs out of gas when #1 loses a flip | Reproduced and fixed (change 1). The proof test `test_leaderLostFlipCallbackMustFitDiceGasLimit` fails before and passes after. Measured with cold storage under the 200k limit: leader loss on 202 players 109,458 gas (deferred), on 13 players 89,558 (deferred), on 12 players 163,526 (rescanned), non-leader loss 76,324, win taking #1 79,214. `FLIP_CALLBACK_GAS` stays at 200,000, the provider's default, so no reliance on Dice honouring larger limits. |
| Low `3e2286a2…` a shield is consumed by a reflect that pays nothing | Reproduced and fixed (change 2). |
| Info `4ccb2af0…` 444 bytes of runtime margin | Taken into account: after the fixes `forge build --sizes` reports `SherwoodV2` at 24,383 bytes of runtime, 193 bytes under the EIP-170 limit; the launcher init code is 26,158 bytes plus 256 bytes of arguments, under the harness's 49,152 limit. The launcher's CREATE2 therefore still succeeds. |
| Info `8e069730…` a debit of the cached leader rescans up to 1,500 players inside the swap | Accepted design, unchanged, as the finding says. The fix for the high finding does not move this rescan into the Dice callback. For the frontend: a move that debits #1 (a Steal of #1, a Robin Hood, a reflect paid by #1, a sell by #1, an expired flip of #1) costs about 4.2k gas per player of the round with cold storage, up to about 6.3M gas at 1,500 players. |

## Behaviour note on the high fix

Between a Dice reveal that costs #1 the lead on a board of more than 12 players and the next play,
sell or flip expiry of that round, no player's King of the Hill clock runs. The old #1 is credited up to
the reveal, the new #1 from the next transaction. In an active round that gap is seconds; a reveal in a
quiet round costs the new #1 the quiet time. The alternative, rescanning in the callback, is exactly
what Dice's gas limit forbids; the alternative of crediting the cached leader optimistically could award
reign time to the wrong player. Nothing else about reign tracking changed: a win, a non-leader loss and
every path outside the callback behave as before.

## Checks run

- `forge build` (solc 0.8.26, via IR, cancun, `bytecode_hash = "none"`), `forge build --sizes`.
- `forge test --no-match-contract Fork`: 207 tests pass (205 of the project plus the proof's 2 in `test/scratch`, which is not submitted).
- `forge test --match-contract Fork` against the public Robinhood Chain RPC: the launcher rehearsal
  `test/SherwoodV2LauncherFork.t.sol` deploys the launcher with the launch's arguments, then does the
  owner setup, a play, settlement and both burns (see the run notes at the end of this file).
- The protected harness check (`.imd/reads/protected/evm_contracts/Contracts.protected.t.sol`) wants
  the deployed runtime under 24,576 bytes with no DELEGATECALL, CALLCODE or SELFDESTRUCT: the launcher's
  runtime is 183 bytes and the hook contains none of those opcodes (its constructor only runs
  `Hooks.validateHookPermissions`, an internal library function).

## Reviewed and left as they are

The focus areas in the brief were read against the code and the tests; nothing else reproduced as a defect.

- Swap deltas: a buy takes the 5% fee in `beforeSwap` with a positive specified delta, so the swapper
  always pays exactly `amountSpecified`; `afterSwap` reverts a partial fill. A sell takes 5% of the ETH
  out through the unspecified delta. The buyback `unlockCallback` settles exactly the ETH the pool took
  (`ethPaid` can only be less than `amount`, never more, for an exact-input swap) and returns the rest
  to the right reserve; `minOut` is the operator's slippage guard.
- Pot and prize accounting: every wei received lands in exactly one of pot, buyback reserve, host
  reserve, an unclaimed prize or referral earnings; settlement awards at most 78% in prizes plus 3.9% in
  referral cuts plus 17% in burns of a pot, so the rollover never underflows and settlement cannot revert
  on arithmetic. Claims are pull-based and guarded; sweeps move unclaimed prizes into the live pot.
- Flip lifecycle: the Dice fee comes out of the pot before the request, a refused request plays as a
  buy, an unrevealed flip expires as a buy after 10 minutes, settlement waits for pending flips, and a
  reveal after settlement is dropped. With change 1 every callback path fits the gas limit.
- Charge clocks: `_charges`, `_spend` and `_nextCharge` never underflow (a clock never passes
  `block.timestamp`) and cap at the bank size.
- King of the Hill: reigns close at the round's end and are finalized once at settlement.

## Open items for the deployer

- The launcher's constructor costs about 10M gas (salt search plus the hook deployment); the gas ceiling
  of the deployment service must allow it. About 1 launch in 400 needs more than 100k tries (about 9M
  gas for the search alone), as the audit noted.
- After deployment the owner (`0x420944b441715e34dd672ae0eb4526a7ad7d1eef`) runs the setup in
  `script/SetupSherwoodV2.s.sol`: create the ETH/$IMD game pool, `setOperator`, `setBuybackPool`
  (the ETH/$IMD 1% pool) and `setHostBuybackPool` (the $PFWA holder pool).

## Revision: King of the Hill on boards above MAX_LEADER_SCAN (finding 5643a8ad, high)

- `src/SherwoodV2.sol`: when the cached leader is stale and the round has more than `MAX_LEADER_SCAN`
  players, `_currentLeader` now returns the marker `UNKNOWN_REIGN` (address(1)) instead of the stale
  cache. The reign goes to that marker, so no real player collects seconds at #1 off a wrong cache.
  The Dice callback's deferred rescan uses the same marker; before, it closed the reign to nobody.
  When settlement finishes, `_crownUnknownReign` adds the marker's seconds to the round's final #1
  (top[0]) and makes that player King if the total out-reigns the current King. Robin Hood does
  nothing while #1 is unknown. It used to target the stale cache, and it spends no charge in this case.
  Swap gas stays bounded: no new scans were added.
- Tests: `test/SherwoodV2LargeBoardKing.t.sol` is the reviewer's proof, with 1,501 players. The two
  callback-deferral tests in `test/SherwoodV2.t.sol` now expect `reignHolder == address(1)` rather
  than `address(0)`.
- Runtime size after the change: 24,534 B, a 42 B margin under EIP-170. The advisory low and info
  findings from this review are left unchanged (see `.imd-responses.json`). Fixing them would need
  more bytecode than this margin allows: the referrer-decode fix alone pushed the hook over the limit.
