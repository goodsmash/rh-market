# RH Market — our own Robinhood Chain launch + marketplace

**GoodsMash RIGS.** A launch-and-trade stack for Robinhood Chain (4663) that keeps
farm wallets and fake volume out, and hands the owner real evidence instead of a
number to trust.

## Where this came from (the review you asked for)

We studied two codebases first.

### 1. REA (`FragFun/DECENTRALIZED`, fork of `morluto/rea`)

It is **not** a marketplace. REA ("Reverse Engineer Anything") is an MCP server and
CLI for taking apart shipped software — binaries, JS/Electron apps, .NET, firmware,
Android and websites — and, on our chain, **offline EVM bytecode**
(`inspect-evm-interface`: recovers function selectors and mutability from a local
bytecode file, no RPC, no wallet).

What we take from it (the part worth copying):

| REA principle | How we use it |
|---|---|
| Every conclusion is an **observation**, an **inference**, or an **unknown** | Our scanner already does this: a flag is evidence with the transactions attached, never a verdict |
| Cite the **evidence**, preserve the **limits** | `master_list.json` carries an example tx per wallet and an explicit `structural_proof` boolean |
| **No implicit actions** — analysis never broadcasts or connects | Our watch tool is read-only; our contracts hold no keys |
| **Route the target first**, don't run setup blindly | `rhwatch.py doctor` before a scan |
| **Summary first**, then drill down | Dashboard first, then per-wallet evidence |

We keep our own EVM work as the primary use; REA is good for taking apart *other
people's* contracts and shipped dApps when a claim depends on a binary we can't read.

### 2. OpenSea (`ProjectOpenSea`)

The useful pieces, all MIT:

- **seaport** — the marketplace protocol. **Live on chain 4663** at
  `0x0000000000000068F116a894984e2DB1123eB395` (v1.6) and
  `0x00000000000000ADc04C56Bf30aC9d3c0aAF14dC` (v1.5). Any collection can trade on
  it today without deploying anything.
- **seadrop** — primary-drop contracts (the Studio mint path).
- **opensea-sdk / seaport-js** — order building and signing.
- **opensea-skill** — an agent skill for the OpenSea API.

We forked all four under `goodsmash/` and synced them to upstream.

## What we build ourselves (this repo)

Seaport already handles *trading*. What it does **not** do is stop a farm from
taking a launch or wash-trading a floor. That is our layer:

| Contract | Job |
|---|---|
| `src/AntiFraudGate.sol` | One reusable gate. Denies contracts and EIP-7702 (automated) wallets, denies a fraud/sanctions list, enforces per-wallet limits and a cooldown, and optionally requires an EIP-712 signed pass from a human check. |
| `src/GoodsMarket.sol` | A fixed-price primary/secondary market: pays ERC-2981 royalties, takes a marketplace fee, and refuses the shapes farms use (no contract buyers, no self-trade, no same-wallet wash). |
| `src/FairLaunch.sol` | A launch on top of the gate: fixed price, per-wallet cap, and a **per-block global cap** so one script cannot clear the launch in a single block. (A post-mint transfer cooldown must live in the NFT itself - a sale contract cannot stop the buyer moving the token afterwards.) |

## What we deliberately do NOT do

**We do not geo-block.** Country filtering is the wrong tool and we will not ship it:

- the sybil attack is location-independent — it cares that a wallet is fresh, not where its owner sits;
- a VPN defeats a geographic rule in one click, so it stops no farm;
- it turns away genuine collectors, which reads as discrimination;
- it is a legal and reputational risk for the collection, not a technical win.

The honest version of "KYC for bad actors" is what `AntiFraudGate` ships: a
**deny list** for wallets we have evidence on, plus optional **signed passes** from
a human check (captcha / social / holder / invite). That raises a farm's cost per
wallet without pretending to know where anyone lives. Sanctions-list screening, if
you want it, is a *list of addresses*, not a map.

## Status — read this honestly

- Contracts: built and tested here (**14/14 tests pass**). **Not audited. Not deployed.**
- The agent never signs or deploys. The owner signs.
- Rehearse on a fork before any mainnet deploy.

## Quick start

```bash
cd contracts
forge install foundry-rs/forge-std --no-git
forge install OpenZeppelin/openzeppelin-contracts --no-git
forge test
```
