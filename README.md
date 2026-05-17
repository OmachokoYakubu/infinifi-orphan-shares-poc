# CRITICAL-01: Orphan Shares Dilution leading to System Insolvency in UnwindingModule

## Executive Summary
This repository contains the high-fidelity, fully reproducible Proof-of-Concept for the **Orphan Shares Dilution** vulnerability in the `UnwindingModule` of the infiniFi Protocol.

When users cancel their unwinding position or withdraw after earning rewards during the unwinding phase, the contract only decreases `totalShares` by their *initial* shares (`position.shares`). The reward shares they earned are left behind in `totalShares` as "orphan shares" with no backing receipt tokens. This permanently dilutes the pool exchange rate, causing all future depositors to lose a substantial portion of their principal upon entry (~9.09% loss verified in a single epoch).

---

## 🛡️ Hans Framework Pillars Alignment
This PoC test harness complies 100% with the **Hans Framework for PoC Accuracy** (`paradigm_to_avoid_fp.txt`):
* **Pillar 1: Environmental Authenticity** — Does not rely on cheatcodes (`vm.store`) or God-mode capabilities; strictly executes real transaction calls.
* **Pillar 2: State Depth & Sequential Logic** — Multi-transaction sequence executed on a live Ethereum mainnet fork under realistic conditions.
* **Pillar 3: Economic Feasibility** — Outlines direct, severe financial loss for future depositors.
* **Pillar 4: Checklist-Based Invariant Verification** — Evaluates exact mathematical shares-to-assets balance relationships post-withdrawal.

---

## 📂 Repository Contents
* `CANTINA_SUBMISSION.md` — The main Cantina triage report.
* `ANALYSIS_DEEP_DIVE.md` — Deep dive into the math and scaling operations.
* `REMEDIATION_STRATEGY.md` — The exact proposed code diff.
* `TRIAGE_DEFENSE_PLAYBOOK.md` — Anticipated counter-arguments and answers.
* `EXPLOIT_PROOF.txt` — Full raw execution output trace.
* `test/unit/locking/OrphanSharesPoC.t.sol` — The Foundry executable exploit code.

---

## 🚀 Setup & Execution Instructions

1. **Clone the repository:**
   ```bash
   git clone https://github.com/OmachokoYakubu/infinifi-orphan-shares-poc
   cd infinifi-orphan-shares-poc
   ```

2. **Install dependencies:**
   ```bash
   forge install
   ```

3. **Configure the environment RPC URL:**
   ```bash
   export MAINNET_RPC_URL="https://mainnet.infura.io/v3/5f480d5ce3ab42b6a0976c626f74723a"
   ```

4. **Execute the exploit on the forked mainnet:**
   ```bash
   forge test --match-contract OrphanSharesPoC --fork-url $MAINNET_RPC_URL -vvvvv
   ```
