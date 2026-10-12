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

## Unresolved defect

The independent large-board proof found that above 1,500 players a stale leader cache can award
68,400 seconds of reign and the 8% King prize to a one-point player, while the true 90-point leader
is correctly ranked #1 at settlement. The failing proof and full inputs are in `.imd-findings.json`.
It was executed under `test/scratch/`; its source is delivered through the findings report, not as an
assertion blessing the incorrect behavior. The six-actor invariant campaign does not cover that
large-board branch. Production code was not modified.
