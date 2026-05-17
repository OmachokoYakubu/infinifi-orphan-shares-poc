# Remediation Strategy: Orphan Shares Dilution

## Vulnerability Overview
The `UnwindingModule` updates the global `totalShares` by only subtracting the user's *initial* shares (`position.shares`) during a cancellation or withdrawal, despite the pool's assets (`totalReceiptTokens`) decreasing by their *current* balance (principal + rewards). This leaves the earned reward shares in `totalShares` as un-burnable orphan shares, permanently diluting all subsequent depositors.

---

## Mitigation Plan

The correct remediation requires that when an unwinding position is removed, the system calculates and subtracts the **entire** current shares (initial shares + reward shares earned during the unwinding period) from `totalShares`.

This matches the exact logic used to compute `userShares` inside `balanceOf()`.

### Proposed Change

Implement the following correction in both `cancelUnwinding` and `withdraw` in `UnwindingModule.sol`:

```diff
// src/locking/UnwindingModule.sol

     function cancelUnwinding(uint256 _startUnwindingTimestamp, uint32 _unwindingEpochs) external returns (uint256) {
         ...
         uint256 userBalance = balanceOf(_owner, _startUnwindingTimestamp);
         ...
         delete positions[id];
 
-        totalShares -= position.shares;
+        uint256 userShares = position.shares;
+        // Calculate actual user shares including rewards earned during unwinding
+        GlobalPoint memory globalPoint;
+        uint256 userRewardWeight = position.fromRewardWeight;
+        uint256 currentEpoch = block.timestamp.epoch();
+        for (uint32 epoch = position.fromEpoch - 1; epoch <= currentEpoch; epoch++) {
+            GlobalPoint memory epochGlobalPoint = globalPoints[epoch];
+            if (epochGlobalPoint.epoch != 0) globalPoint = epochGlobalPoint;
+            if (epoch > position.fromEpoch - 1) {
+                userShares += globalPoint.rewardShares.mulDivDown(userRewardWeight, globalPoint.totalRewardWeight);
+            }
+            globalPoint.totalRewardWeightDecrease -= rewardWeightIncreases[epoch];
+            globalPoint.totalRewardWeightDecrease += rewardWeightDecreases[epoch];
+            globalPoint.totalRewardWeight += rewardWeightBiasIncreases[epoch];
+            globalPoint.totalRewardWeight -= globalPoint.totalRewardWeightDecrease;
+            globalPoint.epoch = epoch + 1;
+            globalPoint.rewardShares = 0;
+            if (epoch >= position.fromEpoch && epoch < position.toEpoch) {
+                userRewardWeight -= position.rewardWeightDecrease;
+            }
+        }
+        totalShares -= userShares;
         totalReceiptTokens -= userBalance;
         ...
     }
```

Repeat the exact same share recalculation logic in the `withdraw` function before decreasing `totalShares`.

---

## Verification of the Fix

After modifying the code:
1. When Alice cancels her position, her initial shares + reward shares are subtracted from `totalShares`, leaving `totalShares = 0` and `totalReceiptTokens = 0`.
2. When Bob enters the pool next, `totalShares` is `0`, so his shares are minted with 100% precision.
3. Bob's principal is fully protected, and he receives exactly the `1000 iUSD` he deposited upon exit, successfully restoring the protocol's solvency invariants.
