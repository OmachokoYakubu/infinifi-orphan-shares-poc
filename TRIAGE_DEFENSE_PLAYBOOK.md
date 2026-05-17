# Triage Defense Playbook: Orphan Shares Dilution

## 1. Triage Classification
*   **Vulnerability Type**: Mathematical Logic / Share Accounting / Solvency Error
*   **Severity**: CRITICAL (System Insolvency / Permanent Loss of Principal)
*   **Impacted Component**: `UnwindingModule.sol` -> `cancelUnwinding` & `withdraw`

---

## 2. Evidence of Vulnerability
*   **Location**: `UnwindingModule.sol` (lines 228 and 264).
*   **Logic**: `totalShares -= position.shares` (burning initial shares only) contrasted with `totalReceiptTokens -= userBalance` (subtracting initial + reward assets).
*   **Proof of Concept**: Compiling and passing on a live forked mainnet environment (`OrphanSharesPoC.t.sol`), showing Bob immediately losing **9.09%** of his principal upon starting unwinding due to Alice's prior reward collection and cancellation.

---

## 3. Anticipated Developer Counter-Arguments

*   *"This only happens if users cancel or withdraw immediately after a reward distribution."*
    *   **Defense**: Unwinding and rewards occur continuously. Any standard user cancellation or withdrawal will trigger this dilution. It is not an edge case; it is a permanent degradation of the exchange rate that gets worse with time and compounding rewards.
*   *"Users can just wait until others withdraw to balance it out."*
    *   **Defense**: The dilution is mathematically locked into `totalShares`. The orphan shares can **never** be removed from the contract. The only way to fix the exchange rate is a complete manual redeployment or upgrading of the contract, meaning all current user funds in the queue are trapped or permanently diluted.
*   *"The rewards shares are supposed to remain behind to pay other users."*
    *   **Defense**: If rewards shares remain behind while their backing assets `totalReceiptTokens` are fully paid out to the withdrawing user, the asset-to-share ratio is completely broken. This means future depositors' fresh principal will back the historical reward shares, directly transferring value from new depositors to historical yield claims. This is a ponzi-like solvency collapse.

---

## 4. Developer Masking Analysis
*   **The Assumption**: Developers assumed that because `position.shares` was the value stored when the position was created, it was the only value that needed to be burned upon cancellation.
*   **The Failure**: They failed to account for the fact that during the unwinding phase, the user's position actively accrues additional `rewardShares` which are added to `totalShares`. By only burning `position.shares`, they left the accrued `rewardShares` stranded as un-backed ghost shares.

---

## 5. Critical Invariants to Monitor
*   **Invariant-01**: `totalReceiptTokens / totalShares == 1.0` (in the absence of losses/rewards, and stable relative to reward additions).
*   **Invariant-02**: `sum(all positions.shares) == totalShares` (excluding global rewards that are actively backed by assets). Stranding reward shares breaks this equivalence.
