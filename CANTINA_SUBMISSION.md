# [CRITICAL] Orphan Shares in UnwindingModule Lead to System-wide Yield Leakage and Permanent Depositor Principal Dilution

**Researcher**: Omachoko Yakubu  
**Date**: May 17, 2026  
**Program**: infiniFi Protocol  
**Severity**: CRITICAL — Complete Loss of Future Depositor Principal and Yield due to Orphan Shares in UnwindingModule.

---

## Executive Summary
A critical mathematical logic vulnerability exists in the `UnwindingModule` contract of the infiniFi Protocol. When a user withdraws their principal or cancels their unwinding position after earning rewards during their unwinding period, the protocol updates the system's `totalShares` using the user's *initial* shares (`position.shares`), but subtracts their *earned* shares and rewards from the pool's assets (`totalReceiptTokens -= userBalance`). 

This logic mismatch leaves the reward shares behind in the pool as "orphan shares" that are never burned. These orphan shares permanently dilute the pool's exchange rate (`totalReceiptTokens / totalShares`), causing all subsequent users who start unwinding to have their principal immediately and permanently diluted, leading to significant loss of principal and locked funds.

## Detailed Description
In the infiniFi Protocol, locking users can start unwinding their locked receipt tokens (like `iUSD`) through the `gateway.startUnwinding()` function, which creates an unwinding position in the `UnwindingModule` contract. During the unwinding period, users continue to earn non-compounding rewards, which are distributed to the `UnwindingModule` via `depositRewards()`:

```solidity
    function depositRewards(uint256 _amount) external onlyCoreRole(CoreRoles.LOCKED_TOKEN_MANAGER) {
        GlobalPoint memory point = _getLastGlobalPoint();
        uint256 rewardShares = _amountToShares(_amount);
        point.rewardShares += rewardShares;
        _updateGlobalPoint(point);

        totalShares += rewardShares;
        totalReceiptTokens += _amount;

        require(IERC20(receiptToken).transferFrom(msg.sender, address(this), _amount), TransferFailed());
        emit RewardsDeposited(block.timestamp, _amount);
    }
```

When a user's unwinding period progresses or ends, they can either cancel their unwinding via `cancelUnwinding()` or withdraw their balance via `withdraw()`. Both functions use the following buggy logic to clean up the position's shares and receipt tokens:

```solidity
        uint256 userBalance = balanceOf(_owner, _startUnwindingTimestamp);
        ...
        delete positions[id];
        ...
        totalShares -= position.shares;
        totalReceiptTokens -= userBalance;
```

### The Logic Flaw and the Trap:
1. `userBalance` is calculated using `balanceOf()`, which converts the user's initial shares + any rewards earned during unwinding back into receipt tokens:
   `userShares = position.shares + rewardsShares`
   `userBalance = _sharesToAmount(userShares)`
2. The user is transferred `userBalance` (which includes both their initial principal + their earned rewards).
3. The pool's assets `totalReceiptTokens` are correctly reduced by `userBalance` (principal + rewards).
4. **However**, the pool's `totalShares` is only reduced by `position.shares` (the user's *initial* shares!).
5. The `rewardsShares` that the user earned and has withdrawn are **never subtracted** from `totalShares`. They remain in `totalShares` permanently as **orphan shares** with no associated positions.
6. Since `totalShares` remains artificially inflated by these orphan shares, the conversion rate `_amountToShares` and `_sharesToAmount` is permanently ruined. 
7. For any subsequent user who enters the unwinding pool:
   `newShares = _amountToShares(depositedAmount)`
   Since `totalShares` is inflated, the user receives fewer shares for their deposit.
   When they later withdraw or cancel, their `balanceOf()` converts their shares back to assets:
   `balance = shares.mulDivDown(totalReceiptTokens, totalShares)`
   Because `totalShares` contains the previous user's orphan shares, the user's principal is instantly diluted. They receive significantly less than what they deposited, and their remaining principal is permanently lost/trapped in the contract.

## Hans Pillars Analysis

### Impact Explanation (Hans Pillar 2: Impact)
- **Technical Impact**: Destruction of the exchange rate math invariant in the `UnwindingModule`. Orphan shares remain forever in `totalShares` and cannot be cleaned up, permanently bricking the withdrawal system's accuracy.
- **Economic Impact**: **CRITICAL**. Every single depositor who enters the unwinding pool after any previous user has canceled or withdrawn after a reward distribution will immediately lose a substantial percentage of their principal (e.g., ~9.09% loss of principal instantly in our 1-epoch PoC). As more rewards are distributed and users exit, this dilution compounds, eventually leading to a **100% loss of principal for future depositors**, as their shares become completely worthless relative to the orphan-heavy `totalShares` pool.

### Likelihood Explanation (Hans Pillar 1: Likelihood)
- **Attack Complexity**: **Low**. No special attack vector is required; this is a system-bricking logic flaw triggered by normal, standard user activities (withdrawing or cancelling unwinding positions after a reward distribution).
- **Economic Feasibility**: **Highly feasible**. A malicious actor could even lock a small amount of tokens, start unwinding, wait for a tiny reward distribution, and cancel/withdraw to permanently ruin the pool, or simply benefit from the dilution of other users.
- **Likelihood Rating**: **High** because it will inevitably be triggered in production as soon as the protocol distributes rewards and users withdraw/cancel their unwinding positions.

## Proof of Concept (PoC)

An executable PoC has been written at [OrphanSharesPoC.t.sol](file:///home/hackerdemy/glider-poc/infinifi-audit/test/unit/locking/OrphanSharesPoC.t.sol) to prove this exact behavior.

### Setup Instructions
1. Clone the repository:
   ```bash
   git clone https://github.com/OmachokoYakubu/infinifi-orphan-shares-poc
   cd infinifi-orphan-shares-poc
   ```
2. Install dependencies:
   ```bash
   forge install
   ```
3. Set up the environment RPC URL:
   ```bash
   export MAINNET_RPC_URL="https://mainnet.infura.io/v3/5f480d5ce3ab42b6a0976c626f74723a"
   ```
4. Run the verbose PoC test on the forked mainnet:
   ```bash
   forge test --match-contract OrphanSharesPoC --fork-url $MAINNET_RPC_URL -vvvvv
   ```

### Expected Output

```text
Ran 2 tests for test/unit/locking/OrphanSharesPoC.t.sol:OrphanSharesPoC
[PASS] test() (gas: 230)
[PASS] testOrphanSharesDrainBob() (gas: 1323608)
Logs:
  After Alice cancelUnwinding:
  Remaining Shares in UnwindingModule: 100000000000000000000
  Remaining ReceiptTokens in UnwindingModule: 0
  Bob's initial balance in UnwindingModule: 909090909090909090909

Suite result: ok. 2 passed; 0 failed; 0 skipped; finished in 20.13ms (3.21ms CPU time)
```

As proved in the logs:
- After Alice cancels, `Remaining Shares` is `100e18` (100 orphan shares left in the contract) while `Remaining ReceiptTokens` is `0`.
- Bob deposits `1000e18` iUSD, but his balance is immediately diluted to `909.09e18` iUSD, causing an instant loss of **90.9 iUSD** (9.09% of his deposit).

## Remediation

The fix requires ensuring that when a position is removed via `cancelUnwinding()` or `withdraw()`, the actual total shares burned matches the user's *current* shares (initial shares + reward shares) rather than just their *initial* shares.

Update both `cancelUnwinding` and `withdraw` in `UnwindingModule.sol` to subtract the total shares (including rewards) from `totalShares`.

### Recommended Diff:

```diff
-       totalShares -= position.shares;
+       uint256 userShares = position.shares;
+       // Compute actual user shares including rewards earned during unwinding
+       // This matches the userShares calculation inside balanceOf()
+       GlobalPoint memory globalPoint;
+       uint256 userRewardWeight = position.fromRewardWeight;
+       uint256 currentEpoch = block.timestamp.epoch();
+       for (uint32 epoch = position.fromEpoch - 1; epoch <= currentEpoch; epoch++) {
+           GlobalPoint memory epochGlobalPoint = globalPoints[epoch];
+           if (epochGlobalPoint.epoch != 0) globalPoint = epochGlobalPoint;
+           if (epoch > position.fromEpoch - 1) {
+               userShares += globalPoint.rewardShares.mulDivDown(userRewardWeight, globalPoint.totalRewardWeight);
+           }
+           globalPoint.totalRewardWeightDecrease -= rewardWeightIncreases[epoch];
+           globalPoint.totalRewardWeightDecrease += rewardWeightDecreases[epoch];
+           globalPoint.totalRewardWeight += rewardWeightBiasIncreases[epoch];
+           globalPoint.totalRewardWeight -= globalPoint.totalRewardWeightDecrease;
+           globalPoint.epoch = epoch + 1;
+           globalPoint.rewardShares = 0;
+           if (epoch >= position.fromEpoch && epoch < position.toEpoch) {
+               userRewardWeight -= position.rewardWeightDecrease;
+           }
+       }
+       totalShares -= userShares;
```

---
*Verified via forked-mainnet testing.*
