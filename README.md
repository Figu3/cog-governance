# COG: Consent-by-Ownership Governance

A novel governance framework for treasury-backed protocols where **ownership implies consent by default**. Token holders who disagree with proposals must actively dissent rather than voting to approve.

## The Problem with Traditional Governance

Traditional DAO governance suffers from several critical issues:

1. **Voter Apathy**: Most token holders never vote, leading to decisions made by tiny minorities
2. **Quorum Gaming**: Proposals fail not because of opposition, but because of insufficient participation
3. **Misaligned Incentives**: Voters bear no cost for bad decisions; proposers risk nothing
4. **Governance Attacks**: Low participation enables hostile takeovers and treasury raids

## The COG Solution

COG inverts the governance model: **silence is consent**. If you hold tokens and don't object, you implicitly approve. This aligns with how ownership actually works - if you own something and don't like how it's being managed, you sell it or speak up.

### Core Principles

1. **Ownership = Consent**: Token holders who don't act are assumed to consent
2. **Skin in the Game**: Proposers stake tokens that get slashed if the proposal fails
3. **Weighted Dissent**: Different dissent actions carry different weights based on commitment level
4. **Economic Exit**: Redemption at NAV is always available, creating a price floor and ultimate veto

## How It Works

### Proposal Lifecycle

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   PROPOSE   │────▶│   ACTIVE    │────▶│   RESOLVE   │
│  (+ stake)  │     │  (7 days)   │     │             │
└─────────────┘     └─────────────┘     └──────┬──────┘
                           │                    │
                           │              ┌─────┴─────┐
                    Dissent Actions       │           │
                    - Veto (1x)      ┌────┴────┐ ┌────┴────┐
                    - Rework (0.5x)  │  PASS   │ │  FAIL   │
                    - Partial (2x)   │(execute)│ │(slash)  │
                    - Full Exit (4x) └─────────┘ └─────────┘
                                           │
                                     ┌─────┴─────┐
                                     │  REWORK   │
                                     │(one try)  │
                                     └───────────┘
```

### Dissent Mechanisms

| Action | Weight | Description |
|--------|--------|-------------|
| **Veto** | 1.0x | Signal opposition without economic action |
| **Rework Request** | 0.5x | Request modifications, not outright rejection |
| **Partial Redemption** | 2.0x | Redeem some tokens at NAV (with 2% haircut during proposals) |
| **Full Exit** | 4.0x | Redeem all tokens - the ultimate dissent signal |

### Dynamic Thresholds

The threshold for proposal failure adapts based on:

```
Threshold = Base (12%) + Impact Adjustment + Concentration - Noise (1%)
```

- **Impact Adjustment**: Higher treasury requests require more dissent to fail
- **Concentration**: More concentrated token distribution raises the threshold
- **Noise Baseline**: Small buffer to filter out noise

### Proposer Stakes

Proposers must lock tokens as stake:
- Minimum: 1% of total supply
- OR: 10% of the requested treasury amount

If the proposal fails, the stake is **burned** (not redistributed), creating real skin in the game.

### Redemption Mechanics

- **Always Available**: Token holders can redeem at NAV anytime
- **Haircut During Proposals**: 2% fee during active proposals creates cost for dissent-by-exit
- **Burns Tokens**: Redemptions reduce supply, maintaining NAV for remaining holders

## Architecture

### Contracts

| Contract | Purpose |
|----------|---------|
| `COGToken` | ERC20 with soft delegation for vote aggregation |
| `COGTreasury` | 100% stablecoin-backed treasury with NAV redemption |
| `COGGovernor` | Proposal lifecycle, threshold calculation, resolution |
| `COGDelegateRegistry` | Optional delegate metadata and reputation tracking |

### Delegation

COG uses "soft delegation" - delegates can vote on behalf of delegators but cannot trigger redemptions. This allows:
- Passive holders to delegate voting to active participants
- Delegators to override their delegate by acting directly
- Delegates to build reputation through voting history

## Example Scenarios

### Scenario 1: Routine Proposal Passes
1. Alice proposes using 10% of treasury for development (stakes 1% of supply)
2. Small holder Bob vetoes (5% weight)
3. No other dissent during 7-day window
4. Threshold: 13%, Dissent: 5% → **PASSES**
5. Treasury transfers funds, Alice gets stake back

### Scenario 2: Controversial Proposal Fails
1. Alice proposes 30% treasury spend (stakes 3%)
2. Multiple holders veto (25% combined weight)
3. Some holders redeem fully (20% × 4x = 80% weight)
4. Threshold: 17%, Dissent: 105% → **FAILS**
5. Alice's stake is burned

### Scenario 3: Proposal Gets Reworked
1. Alice proposes 20% spend
2. Holders request rework instead of vetoing
3. Rework signal exceeds 60% of threshold
4. Proposal enters REWORK state
5. Alice resubmits with 10% spend
6. New voting period, proposal passes

## Security Considerations

- **Reentrancy Protection**: All state-changing functions use ReentrancyGuard
- **Flash Loan Resistance**: Token balances snapshotted at proposal creation
- **Double-Voting Prevention**: Each address can only act once per proposal
- **HHI Snapshot**: Concentration calculated at proposal creation, not resolution

## Getting Started

### Build
```bash
forge build
```

### Test
```bash
forge test
```

### Deploy
1. Deploy `COGToken`
2. Deploy `COGTreasury` (with token address)
3. Deploy `COGGovernor` (with token and treasury addresses)
4. Deploy `COGDelegateRegistry` (optional)
5. Call `token.setTreasury(treasury)`
6. Call `treasury.setGovernor(governor)`
7. Mint initial tokens and fund treasury

## Configuration

| Parameter | Value | Description |
|-----------|-------|-------------|
| `BASE_THRESHOLD` | 12% | Base dissent required to fail |
| `NOISE_BASELINE` | 1% | Threshold reduction for noise |
| `PROPOSAL_WINDOW` | 7 days | Voting period duration |
| `PROPOSER_COOLDOWN` | 14 days | Time between proposals from same address |
| `REDEMPTION_HAIRCUT` | 2% | Fee during active proposals |
| `MAX_TREASURY_IMPACT` | 50% | Maximum single proposal size |

## Why COG Works

1. **Addresses Apathy**: Non-voters implicitly support proposals, solving participation problems
2. **Creates Accountability**: Proposers risk real capital, filtering low-quality proposals
3. **Enables Exit**: Unhappy holders can always redeem, preventing value extraction
4. **Scales Naturally**: More tokens = more implicit consent, aligning with economic reality
5. **Resists Attacks**: Would-be attackers must overcome both opposition AND economic exit

## License

MIT
