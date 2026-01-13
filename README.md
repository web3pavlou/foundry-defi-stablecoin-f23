
# DWebThreePavlouStableCoin (DWTPSC)

# About
A minimal, overcollateralized USD-pegged stablecoin system inspired by CDP-style designs (e.g., DAI-like mechanics without governance/modules).

---

## Design Considerations
### Peg model
- Target peg: **1 DWTPSC ≈ $1**
- Properties:
  - **Exogenous collateral** (WETH/WBTC)
  - **Dollar-pegged**
  - **Algorithmic stability** via overcollateralization + liquidation incentives (no stability module)


- **Health factor** is computed as:
`HF = (collateralUsd * liquidationThreshold / 100) / debtUsd` scaled by `1e18`

  - Healthy when **HF ≥ 1e18**
  - This corresponds to roughly **200% minimum collateralization**

- **Liquidation bonus:** **10%**
  - Bonus is **dynamically reduced** if the vault doesn’t have enough collateral to pay the full bonus (prevents liquidation being blocked for near-100% collateralization edge cases).
- **Minimum position value:** default **$250** (`s_minPositionValueUsd`)
  - Prevents opening positions too small to be economical.
- **Dust rule (per-collateral):** `s_minDebtThreshold[token]`


---

## Collateral
Supported collateral (configured at deployment):
- **WETH**
- **WBTC**



---

## Price Feeds / Oracle Safety (OracleLib)
All valuations rely on Chainlink feeds via `OracleLib.staleCheckLatestRoundData(maxPriceAge)`.

OracleLib enforces:
- Round sanity: `updatedAt != 0`, `updatedAt <= block.timestamp`, `answeredInRound >= roundId`
- **Staleness bound**: reverts if price is older than `maxPriceAge`
  - Default: **3 hours**
  - Per-collateral override via `DSCEngine.setMaxPriceAge(token, maxPriceAge)`
- **Price bounds** for known feed addresses (guards against absurd prices / feed failures)
- **L2 sequencer uptime checks** (revert if sequencer down or grace period not over):
  - **Arbitrum One**
  - **zkSync Mainnet**



---

## Liquidation
A position becomes liquidatable when:
- `healthFactor(user) < 1e18`

Liquidation (`liquidate(collateral, user, debtToCover)`):
- Clamps `debtToCover` so the engine never burns more than the user’s debt -and never burns beyond the USD value of the deposited collateral of that token-.
- Enforces **dust** constraints (`minDebtThreshold`) on remaining debt.
- Seizes collateral equal to the covered debt’s USD value + **10% bonus** (bonus reduced if collateral is insufficient).
- Reverts if the liquidation does not improve the user’s health factor.

Also supported:
- `batchLiquidate(collateral, users[], debtsToCover[])` for atomic multi-user liquidation batches.



---

## Flash Minting (IERC3156)
`FlashMintDWebThreePavlou` implements **IERC3156FlashLender** for **DWTPSC only**.

Key properties:
- DSCEngine acts as the **risk manager**:
  - `maxFlashLoan = min(systemCollateralUsd - totalSupply, 1,000,000 DWTPSC)`
  - If `systemCollateralUsd <= supply`, flash headroom is **0**
- Fee is configured in DSCEngine using `setFlashFeeBps(bps)` and rounded **up**(Default==0).




---

## Getting Started

### Requirements

* [Foundry](https://book.getfoundry.sh/) (`forge`, `cast`, `anvil`)

### Install

```bash
forge install
forge build
```

---

## Testing

The codebase is heavily tested (unit + fuzz/invariants) with >95% coverage on main contracts.

Run all tests:

```bash
forge test
```

Verbose:

```bash
forge test -vvvv
```

Coverage:

```bash
forge coverage
```

Run only unit tests:

```bash
forge test --match-path "test/Unit/*"
```

Run invariants (stop-on-revert / fail-on-revert style):

```bash
forge test --match-path "test/Fuzz/failOnRevert/*" -vvvv
```

Run invariants (continue-on-revert style):

```bash
forge test --match-path "test/Fuzz/continueOnRevert/*" -vvvv
```

Formatting:

```bash
forge fmt
```

---

## Deployment

Deployment script: `script/DeployDSC.s.sol`



`DeployDSC.run()`:



### Example (Sepolia)

Set:

* `SEPOLIA_RPC_URL`
* `PRIVATE_KEY`

Then:

```bash
forge script script/DeployDSC.s.sol:DeployDSC \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

(If you use a Makefile wrapper:)

```bash
make deploy ARGS="--network sepolia"
```

---

## Limitations

* **Crash / drawdown insolvency risk:** rapid collateral drops + delayed liquidations can undercollateralize the system and break the peg.
* **No emergency shutdown / global settlement:** there is no “cage/end” module for orderly wind-down.
* **Oracle liveness dependency:** stale/unavailable feeds halt key actions (intentional safety design). Sequencer uptime checks exist for Arbitrum/zkSync.
* **Liquidation market dependency:** keeper participation, congestion, MEV conditions can delay liquidations.
* **Admin parameter risk:** owner can change risk posture (min position value, dust thresholds, flash fee, max price age, flash minter wiring).

---
## License

This project is licensed under the [MIT License](LICENSE).


