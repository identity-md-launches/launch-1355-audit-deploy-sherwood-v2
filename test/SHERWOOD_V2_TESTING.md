# Sherwood v2 independent tests

Run `forge build` and `forge test`. No new dependencies or configuration changes are needed.

The existing fork suites now skip unless `SHERWOOD_FORK_RPC_URL` is explicitly supplied. To rehearse
against Robinhood Chain, run `SHERWOOD_FORK_RPC_URL='<RPC URL>' forge test --match-contract Fork`.
No live fork was run for this contribution. The actual PFWA holder hook, Dice provider, deployed
pool liquidity, and the launcher's gas at the eventual factory address still need that rehearsal.

## Added coverage

- `SherwoodV2Accounting.t.sol`: actual ETH and token balances across real v4 swaps; one-wei and fee
  rounding boundaries; total rollback of a partially filled game buy, including Dice state and
  charges; partial fills of both buybacks; missing liquidity; slippage rollback; batched settlement
  equivalence with partial holdings and referrals; claim/sweep deadline exclusivity; access control.
- `SherwoodV2BuybackHook.t.sol`: both burns through a local dynamic-fee v4 pool whose hook takes
  specified ETH and unspecified token deltas. Minimum output is checked against net tokens actually
  burned, and failed slippage rolls back external hook fees. This is an adversarial integration
  stand-in, not a replica or verification of the live PFWA holder hook.
- `SherwoodV2Lifecycle.t.sol`: Dice fee-lookup/request failure, fee-cap and insufficient-pot cases,
  concurrent flips resolved out of order, duplicate/unknown/late callbacks, exact expiry recovery,
  refund accounting, settlement recovery, exact charge boundaries and fractional recharge,
  referral transfer failure and reentry into all three guarded withdrawal functions.
- `SherwoodV2Launcher.t.sol`: onchain salt mining and real CREATE2 deployment from a local factory
  with the brief's fixed dependency addresses and an explicit test owner, on an empty chain with
  chain ID 4663. Checks the published salt/address, permissions, constructor wiring, runtime/init
  code sizes, and separation between factory and owner. It does not assume deployment fits a
  universal 10M gas ceiling: salt-search cost depends on the factory address and init code.

Each stateless fuzz property runs 1,000 examples using inline Foundry configuration.

## Stateful properties

`SherwoodV2Invariant.t.sol` uses six actors, the real v4 PoolManager, ordinary local ERC20s, and a
controlled Dice transport. The handler randomly buys with all five moves, sells, transfers game or
host holdings, funds current/future pots, advances time, changes Dice availability/fees, reveals or
expires requests, settles in batches, claims prizes/referrals, sweeps, refunds, and executes both burns.
The suite runs 256 sequences of depth 96, with unexpected reverts treated as failures.

The following properties are checked after every handler call:

1. ETH equals all unsettled pots, unpaid prizes, referral balances, and both burn reserves. Settled
   pot mappings are historical totals and are not counted a second time.
2. An independent ledger of seed deposits, swap fees, Dice payments/refunds, payouts and burns
   reconciles to ETH held; total outflows never exceed inflows.
3. Settled rankings, scores, prize amounts, holding requirements, and deadlines never change.
4. Final rankings match positive scores, the King maximizes recorded reign time with the score
   tiebreak, and reign seconds do not overlap.
5. Pending-flip counters equal the actual live requests, each still unresolved at Dice.
6. Charge counts and next-recharge times agree with their caps and intervals; on the small board,
   no player outranks the active reign holder.

The handler never funds the hook, manager, or Dice with `deal`, never changes production storage,
and never swallows unexpected failures. A deterministic handler exercise checks that claims,
referrals, both burn paths, expiry, reveal, refund, selling and sweeping are reachable. Normal funding
is modeled; forced ETH transfers are outside this exact-liability equality. Refund eligibility is
controlled by the local Dice transport, not a claim about the live provider's refund delay.

## Revision: the UNKNOWN_REIGN marker (finding 5643a8ad)

The large-board King finding from the previous round was fixed by parking the reign on `address(1)`
whenever the cached leader of a round with more than 1,500 players is debited, and crediting the
marker's seconds to the round's final #1 at settlement. `SherwoodV2UnknownReign.t.sol` covers that
revision on real 1,501-player boards and on a 13-player board for the deferred Dice rescan:

- the marker takes the reign on the first debit of the cached leader, no real player accumulates
  seconds off the stale cache, the cache keeps moving to credited players, and the marker's running
  reign is capped at the round's end with no overlap;
- the marker's seconds crown the final #1 only on the settlement batch that reaches the end of the
  board, a longer real reign still beats them, a round with nobody above zero gets no prize, and
  `address(1)` can never claim anything;
- Robin Hood while #1 is unknown scores the buy, moves nothing and spends no charge (by the player and
  by the stale cached leader), while a 1,500-player board is still rescanned in place;
- a lost flip by #1 on 13 players defers the rescan to the marker, the next play rescans, an expired
  flip leaves no marker, and the marker does not leak into the next round.

Times in that file are derived from `GENESIS`, never from a cached `block.timestamp`: under via-IR
the compiler re-reads the opcode at each use, so a cached value moves with every `vm.warp`.

## Reported, not asserted

The marker credits every unknown second to whoever is #1 at the end, so on a big board a player who
takes #1 in the last minutes is crowned King over the player who actually held #1 for most of the
round. The failing proof (1,501 players, 18 hours versus 1 hour) and three smaller findings (Robin
Hood silently disabled for the rest of a big round, `settle` with `type(uint256).max` panicking after
a partial batch, and views that exclude the marker's seconds) are in `.imd-findings.json`. The
six-actor invariant campaign never reaches the big-board branch. Production code was not modified.
