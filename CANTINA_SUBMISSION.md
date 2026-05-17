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

Traces:
  [1659775] OrphanSharesPoC::testOrphanSharesDrainBob()
    ├─ [19720] redeemController::receiptToAsset(1000000000000000000000 [1e21]) [staticcall]
    │   ├─ [7830] accounting::price(usdc: [0xc7183455a4C133Ae270771860664b6B7ec320bB1]) [staticcall]
    │   │   ├─ [2338] oracleUsdc::price() [staticcall]
    │   │   │   └─ ← [Return] 1000000000000000000000000000000 [1e30]
    │   │   └─ ← [Return] 1000000000000000000000000000000 [1e30]
    │   ├─ [7830] accounting::price(iusd: [0xF62849F9A0B5Bf2913b396098F7c7019b51A820a]) [staticcall]
    │   │   ├─ [2338] oracleIusd::price() [staticcall]
    │   │   │   └─ ← [Return] 1000000000000000000 [1e18]
    │   │   └─ ← [Return] 1000000000000000000 [1e18]
    │   └─ ← [Return] 1000000000 [1e9]
    ├─ [46898] usdc::mint(mintController: [0x3D7Ebc40AF7092E3F1C81F2e996cbA5Cae2090d7], 1000000001 [1e9])
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: mintController: [0x3D7Ebc40AF7092E3F1C81F2e996cbA5Cae2090d7], value: 1000000001 [1e9])
    │   └─ ← [Return] 1
    ├─ [0] VM::prank(mintController: [0x3D7Ebc40AF7092E3F1C81F2e996cbA5Cae2090d7])
    │   └─ ← [Return]
    ├─ [54619] iusd::mint(Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea], 1000000000000000000000 [1e21])
    │   ├─ [2702] core::hasRole(0x615a688d53344290b742a2e72e4f187e5b88227c01f9d77ce2406d32f8bd0eda, mintController: [0x3D7Ebc40AF7092E3F1C81F2e996cbA5Cae2090d7]) [staticcall]
    │   │   └─ ← [Return] true
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea], value: 1000000000000000000000 [1e21])
    │   └─ ← [Stop]
    ├─ [0] VM::startPrank(Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea])
    │   └─ ← [Return]
    ├─ [24757] iusd::approve(gateway: [0xe8dc788818033232EF9772CB2e6622F1Ec8bc840], 1000000000000000000000 [1e21])
    │   ├─ emit Approval(owner: Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea], spender: gateway: [0xe8dc788818033232EF9772CB2e6622F1Ec8bc840], value: 1000000000000000000000 [1e21])
    │   └─ ← [Return] true
    ├─ [231869] gateway::fallback(1000000000000000000000 [1e21], 10, Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea])
    │   ├─ [226924] InfiniFiGatewayV1::createPosition(1000000000000000000000 [1e21], 10, Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea]) [delegatecall]
    │   │   ├─ [26068] iusd::transferFrom(Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea], gateway: [0xe8dc788818033232EF9772CB2e6622F1Ec8bc840], 1000000000000000000000 [1e21])
    │   │   │   ├─ emit Transfer(from: Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea], to: gateway: [0xe8dc788818033232EF9772CB2e6622F1Ec8bc840], value: 1000000000000000000000 [1e21])
    │   │   │   └─ ← [Return] true
    │   │   ├─ [24757] iusd::approve(lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7], 1000000000000000000000 [1e21])
    │   │   │   ├─ emit Approval(owner: gateway: [0xe8dc788818033232EF9772CB2e6622F1Ec8bc840], spender: lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7], value: 1000000000000000000000 [1e21])
    │   │   │   └─ ← [Return] true
    │   │   ├─ [164407] lockingController::createPosition(1000000000000000000000 [1e21], 10, Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea])
    │   │   │   ├─ [2702] core::hasRole(0x276ea66e969b021a947c47a128f4d53c55387336443ef7a5391a75f0d2e48d25, gateway: [0xe8dc788818033232EF9772CB2e6622F1Ec8bc840]) [staticcall]
    │   │   │   │   └─ ← [Return] true
    │   │   │   ├─ [26068] iusd::transferFrom(gateway: [0xe8dc788818033232EF9772CB2e6622F1Ec8bc840], lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7], 1000000000000000000000 [1e21])
    │   │   │   │   ├─ emit Transfer(from: gateway: [0xe8dc788818033232EF9772CB2e6622F1Ec8bc840], to: lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7], value: 1000000000000000000000 [1e21])
    │   │   │   │   └─ ← [Return] true
    │   │   │   ├─ [2371] liUSD-10w::totalSupply() [staticcall]
    │   │   │   │   └─ ← [Return] 0
    │   │   │   ├─ [52347] liUSD-10w::mint(Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea], 1000000000000000000000 [1e21])
    │   │   │   │   ├─ [2702] core::hasRole(0xc46edb8291bbe8016e3c83529d0eb01c2733d265fc4594ac6299b3ef72721546, lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7]) [staticcall]
    │   │   │   │   │   └─ ← [Return] true
    │   │   │   │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea], value: 1000000000000000000000 [1e21])
    │   │   │   │   └─ ← [Stop]
    │   │   │   ├─ emit PositionCreated(timestamp: 1733412513 [1.733e9], user: Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea], amount: 1000000000000000000000 [1e21], unwindingEpochs: 10)
    │   │   │   └─ ← [Stop]
    │   │   └─ ← [Stop]
    │   └─ ← [Return]
    ├─ [0] VM::stopPrank()
    │   └─ ← [Return]
    ├─ [0] VM::startPrank(Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea])
    │   └─ ← [Return]
    ├─ [660] lockingController::shareToken(10) [staticcall]
    │   └─ ← [Return] liUSD-10w: [0x94771550282853f6E0124c302F7dE1Cf50aa45CA]
    ├─ [24780] liUSD-10w::approve(gateway: [0xe8dc788818033232EF9772CB2e6622F1Ec8bc840], 1000000000000000000000 [1e21])
    │   ├─ emit Approval(owner: Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea], spender: gateway: [0xe8dc788818033232EF9772CB2e6622F1Ec8bc840], value: 1000000000000000000000 [1e21])
    │   └─ ← [Return] true
    ├─ [357367] gateway::fallback(1000000000000000000000 [1e21], 10)
    │   ├─ [356928] InfiniFiGatewayV1::startUnwinding(1000000000000000000000 [1e21], 10) [delegatecall]
    │   │   ├─ [300296] lockingController::startUnwinding(1000000000000000000000 [1e21], 10, Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea])
    │   │   │   ├─ [229101] unwindingModule::startUnwinding(Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea], 1000000000000000000000 [1e21], 10, 1200000000000000000000 [1.2e21])
    │   │   │   │   ├─ emit GlobalPointUpdated(timestamp: 1733412513 [1.733e9], : GlobalPoint({ epoch: 2865, totalRewardWeight: 0, totalRewardWeightDecrease: 0, rewardShares: 0 }))
    │   │   │   │   ├─ emit UnwindingStarted(timestamp: 1733412513 [1.733e9], user: Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea], receiptTokens: 1000000000000000000000 [1e21], unwindingEpochs: 10, rewardWeight: 1200000000000000000000 [1.2e21])
    │   │   │   │   └─ ← [Stop]
    │   │   │   ├─ [25195] iusd::transfer(unwindingModule: [0x96d3F6c20EEd2697647F543fE6C08bC2Fbf39758], 1000000000000000000000 [1e21])
    │   │   │   │   ├─ emit Transfer(from: lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7], to: unwindingModule: [0x96d3F6c20EEd2697647F543fE6C08bC2Fbf39758], value: 1000000000000000000000 [1e21])
    │   │   │   │   └─ ← [Return] true
    │   │   │   └─ ← [Stop]
    │   │   └─ ← [Stop]
    │   └─ ← [Return]
    ├─ [0] VM::stopPrank()
    │   └─ ← [Return]
    ├─ [0] VM::warp(1734017313 [1.734e9])
    │   └─ ← [Return]
    ├─ [3098] usdc::mint(mintController: [0x3D7Ebc40AF7092E3F1C81F2e996cbA5Cae2090d7], 100000001 [1e8])
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: mintController: [0x3D7Ebc40AF7092E3F1C81F2e996cbA5Cae2090d7], value: 100000001 [1e8])
    │   └─ ← [Return] 1
    ├─ [0] VM::prank(mintController: [0x3D7Ebc40AF7092E3F1C81F2e996cbA5Cae2090d7])
    │   └─ ← [Return]
    ├─ [26219] iusd::mint(yieldSharing: [0xDB25A7b768311dE128BBDa7B8426c3f9C74f3240], 100000000000000000000 [1e20])
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: yieldSharing: [0xDB25A7b768311dE128BBDa7B8426c3f9C74f3240], value: 100000000000000000000 [1e20])
    │   └─ ← [Stop]
    ├─ [0] VM::startPrank(yieldSharing: [0xDB25A7b768311dE128BBDa7B8426c3f9C74f3240])
    │   └─ ← [Return]
    ├─ [7657] iusd::approve(lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7], 100000000000000000000 [1e20])
    │   └─ ← [Return] true
    ├─ [121263] lockingController::depositRewards(100000000000000000000 [1e20])
    │   ├─ emit RewardsDeposited(timestamp: 1734017313 [1.734e9], amount: 100000000000000000000 [1e20])
    │   ├─ [24068] iusd::transferFrom(yieldSharing: [0xDB25A7b768311dE128BBDa7B8426c3f9C74f3240], lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7], 100000000000000000000 [1e20])
    │   │   ├─ emit Transfer(from: yieldSharing: [0xDB25A7b768311dE128BBDa7B8426c3f9C74f3240], to: lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7], value: 100000000000000000000 [1e20])
    │   │   └─ ← [Return] true
    │   ├─ [79558] unwindingModule::depositRewards(100000000000000000000 [1e20])
    │   │   ├─ emit GlobalPointUpdated(timestamp: 1734017313 [1.734e9], : GlobalPoint({ epoch: 2866, totalRewardWeight: 1200000000000000000000 [1.2e21], totalRewardWeightDecrease: 0, rewardShares: 100000000000000000000 [1e20] }))
    │   │   └─ ← [Stop]
    │   ├─ [3295] iusd::transfer(unwindingModule: [0x96d3F6c20EEd2697647F543fE6C08bC2Fbf39758], 100000000000000000000 [1e20])
    │   │   ├─ emit Transfer(from: lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7], to: unwindingModule: [0x96d3F6c20EEd2697647F543fE6C08bC2Fbf39758], value: 100000000000000000000 [1e20])
    │   │   └─ ← [Return] true
    │   └─ ← [Stop]
    ├─ [0] VM::stopPrank()
    │   └─ ← [Return]
    ├─ [11185] unwindingModule::balanceOf(Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea], 1733412513 [1.733e9]) [staticcall]
    │   └─ ← [Return] 1100000000000000000000 [1.1e21]
    ├─ [0] VM::assertApproxEqAbs(1100000000000000000000 [1.1e21], 1100000000000000000000 [1.1e21], 1000000000000000 [1e15], "Alice should have earned 100 iUSD in rewards") [staticcall]
    │   └─ ← [Return]
    ├─ [0] VM::startPrank(Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea])
    │   └─ ← [Return]
    ├─ [184435] gateway::fallback(1733412513 [1.733e9], 10)
    │   ├─ [183996] InfiniFiGatewayV1::cancelUnwinding(1733412513 [1.733e9], 10) [delegatecall]
    │   │   ├─ [182414] lockingController::cancelUnwinding(Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea], 1733412513 [1.733e9], 10)
    │   │   │   ├─ [180112] unwindingModule::cancelUnwinding(Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea], 1733412513 [1.733e9], 10)
    │   │   │   │   ├─ emit GlobalPointUpdated(timestamp: 1734017313 [1.734e9], : GlobalPoint({ epoch: 2866, totalRewardWeight: 0, totalRewardWeightDecrease: 0, rewardShares: 100000000000000000000 [1e20] }))
    │   │   │   │   ├─ [24757] iusd::approve(lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7], 1100000000000000000000 [1.1e21])
    │   │   │   │   │   ├─ emit Approval(owner: unwindingModule: [0x96d3F6c20EEd2697647F543fE6C08bC2Fbf39758], spender: lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7], value: 1100000000000000000000 [1.1e21])
    │   │   │   │   │   └─ ← [Return] true
    │   │   │   │   ├─ [134617] lockingController::createPosition(1100000000000000000000 [1.1e21], 10, Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea])
    │   │   │   │   │   │   ├─ [24068] iusd::transferFrom(unwindingModule: [0x96d3F6c20EEd2697647F543fE6C08bC2Fbf39758], lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7], 1100000000000000000000 [1.1e21])
    │   │   │   │   │   │   │   ├─ emit Transfer(from: unwindingModule: [0x96d3F6c20EEd2697647F543fE6C08bC2Fbf39758], to: lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7], value: 1100000000000000000000 [1.1e21])
    │   │   │   │   │   │   │   └─ ← [Return] true
    │   │   │   │   │   │   ├─ [44347] liUSD-10w::mint(Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea], 1100000000000000000000 [1.1e21])
    │   │   │   │   │   │   │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea], value: 1100000000000000000000 [1.1e21])
    │   │   │   │   │   │   │   └─ ← [Stop]
    │   │   │   │   │   │   ├─ emit PositionCreated(timestamp: 1734017313 [1.734e9], user: Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea], amount: 1100000000000000000000 [1.1e21], unwindingEpochs: 10)
    │   │   │   │   │   │   └─ ← [Stop]
    │   │   │   │   │   └─ ← [Stop]
    │   │   │   │   ├─ emit UnwindingCanceled(timestamp: 1734017313 [1.734e9], user: Alice: [0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea], startUnwindingTimestamp: 1733412513 [1.733e9], newUnwindingEpochs: 10)
    │   │   │   │   └─ ← [Stop]
    │   │   │   └─ ← [Stop]
    │   │   └─ ← [Stop]
    │   └─ ← [Return]
    ├─ [0] VM::stopPrank()
    │   └─ ← [Return]
    ├─ [329] unwindingModule::totalShares() [staticcall]
    │   └─ ← [Return] 100000000000000000000 [1e20]
    ├─ [350] unwindingModule::totalReceiptTokens() [staticcall]
    │   └─ ← [Return] 0
    ├─ [0] console::log("After Alice cancelUnwinding:") [staticcall]
    │   └─ ← [Stop]
    ├─ [0] console::log("Remaining Shares in UnwindingModule:", 100000000000000000000 [1e20]) [staticcall]
    │   └─ ← [Stop]
    ├─ [0] console::log("Remaining ReceiptTokens in UnwindingModule:", 0) [staticcall]
    │   └─ ← [Stop]
    ├─ [0] VM::assertApproxEqAbs(100000000000000000000 [1e20], 100000000000000000000 [1e20], 1000000000000000 [1e15], "Orphan shares should be left in UnwindingModule") [staticcall]
    │   └─ ← [Return]
    ├─ [0] VM::assertEq(0, 0, "Receipt tokens in UnwindingModule should be 0") [staticcall]
    │   └─ ← [Return]
    ├─ [3098] usdc::mint(mintController: [0x3D7Ebc40AF7092E3F1C81F2e996cbA5Cae2090d7], 1000000001 [1e9])
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: mintController: [0x3D7Ebc40AF7092E3F1C81F2e996cbA5Cae2090d7], value: 1000000001 [1e9])
    │   └─ ← [Return] 1
    ├─ [0] VM::prank(mintController: [0x3D7Ebc40AF7092E3F1C81F2e996cbA5Cae2090d7])
    │   └─ ← [Return]
    ├─ [26219] iusd::mint(Bob: [0x4dBa461cA9342F4A6Cf942aBd7eacf8AE259108C], 1000000000000000000000 [1e21])
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: Bob: [0x4dBa461cA9342F4A6Cf942aBd7eacf8AE259108C], value: 1000000000000000000000 [1e21])
    │   └─ ← [Stop]
    ├─ [0] VM::startPrank(Bob: [0x4dBa461cA9342F4A6Cf942aBd7eacf8AE259108C])
    │   └─ ← [Return]
    ├─ [24757] iusd::approve(gateway: [0xe8dc788818033232EF9772CB2e6622F1Ec8bc840], 1000000000000000000000 [1e21])
    │   └─ ← [Return] true
    ├─ [88899] gateway::fallback(1000000000000000000000 [1e21], 10, Bob: [0x4dBa461cA9342F4A6Cf942aBd7eacf8AE259108C])
    │   ├─ [88454] InfiniFiGatewayV1::createPosition(1000000000000000000000 [1e21], 10, Bob: [0x4dBa461cA9342F4A6Cf942aBd7eacf8AE259108C]) [delegatecall]
    │   │   ├─ [24068] iusd::transferFrom(Bob: [0x4dBa461cA9342F4A6Cf942aBd7eacf8AE259108C], gateway: [0xe8dc788818033232EF9772CB2e6622F1Ec8bc840], 1000000000000000000000 [1e21])
    │   │   │   ├─ emit Transfer(from: Bob: [0x4dBa461cA9342F4A6Cf942aBd7eacf8AE259108C], to: gateway: [0xe8dc788818033232EF9772CB2e6622F1Ec8bc840], value: 1000000000000000000000 [1e21])
    │   │   │   └─ ← [Return] true
    │   │   ├─ [22657] iusd::approve(lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7], 1000000000000000000000 [1e21])
    │   │   │   └─ ← [Return] true
    │   │   ├─ [38537] lockingController::createPosition(1000000000000000000000 [1e21], 10, Bob: [0x4dBa461cA9342F4A6Cf942aBd7eacf8AE259108C])
    │   │   │   ├─ [4168] iusd::transferFrom(gateway: [0xe8dc788818033232EF9772CB2e6622F1Ec8bc840], lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7], 1000000000000000000000 [1e21])
    │   │   │   │   ├─ emit Transfer(from: gateway: [0xe8dc788818033232EF9772CB2e6622F1Ec8bc840], to: lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7], value: 1000000000000000000000 [1e21])
    │   │   │   │   └─ ← [Return] true
    │   │   │   ├─ [371] liUSD-10w::totalSupply() [staticcall]
    │   │   │   │   └─ ← [Return] 1100000000000000000000 [1.1e21]
    │   │   │   ├─ [26447] liUSD-10w::mint(Bob: [0x4dBa461cA9342F4A6Cf942aBd7eacf8AE259108C], 1000000000000000000000 [1e21])
    │   │   │   │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: Bob: [0x4dBa461cA9342F4A6Cf942aBd7eacf8AE259108C], value: 1000000000000000000000 [1e21])
    │   │   │   │   └─ ← [Stop]
    │   │   │   ├─ emit PositionCreated(timestamp: 1734017313 [1.734e9], user: Bob: [0x4dBa461cA9342F4A6Cf942aBd7eacf8AE259108C], amount: 1000000000000000000000 [1e21], unwindingEpochs: 10)
    │   │   │   └─ ← [Stop]
    │   │   └─ ← [Stop]
    │   └─ ← [Return]
    ├─ [0] VM::stopPrank()
    │   └─ ← [Return]
    ├─ [0] VM::startPrank(Bob: [0x4dBa461cA9342F4A6Cf942aBd7eacf8AE259108C])
    │   └─ ← [Return]
    ├─ [660] lockingController::shareToken(10) [staticcall]
    │   └─ ← [Return] liUSD-10w: [0x94771550282853f6E0124c302F7dE1Cf50aa45CA]
    ├─ [24780] liUSD-10w::approve(gateway: [0xe8dc788818033232EF9772CB2e6622F1Ec8bc840], 1000000000000000000000 [1e21])
    │   └─ ← [Return] true
    ├─ [300354] gateway::fallback(1000000000000000000000 [1e21], 10)
    │   ├─ [299915] InfiniFiGatewayV1::startUnwinding(1000000000000000000000 [1e21], 10) [delegatecall]
    │   │   ├─ [247383] lockingController::startUnwinding(1000000000000000000000 [1e21], 10, Bob: [0x4dBa461cA9342F4A6Cf942aBd7eacf8AE259108C])
    │   │   │   ├─ [24274] liUSD-10w::transferFrom(gateway: [0xe8dc788818033232EF9772CB2e6622F1Ec8bc840], lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7], 1000000000000000000000 [1e21])
    │   │   │   │   ├─ emit Transfer(from: gateway: [0xe8dc788818033232EF9772CB2e6622F1Ec8bc840], to: lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7], value: 1000000000000000000000 [1e21])
    │   │   │   │   └─ ← [Return] true
    │   │   │   ├─ [4499] liUSD-10w::burn(1000000000000000000000 [1e21])
    │   │   │   │   ├─ emit Transfer(from: lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7], to: 0x0000000000000000000000000000000000000000, value: 1000000000000000000000 [1e21])
    │   │   │   │   └─ ← [Stop]
    │   │   │   ├─ [186701] unwindingModule::startUnwinding(Bob: [0x4dBa461cA9342F4A6Cf942aBd7eacf8AE259108C], 1000000000000000000000 [1e21], 10, 1200000000000000000000 [1.2e21])
    │   │   │   │   ├─ emit GlobalPointUpdated(timestamp: 1734017313 [1.734e9], : GlobalPoint({ epoch: 2866, totalRewardWeight: 0, totalRewardWeightDecrease: 0, rewardShares: 100000000000000000000 [1e20] }))
    │   │   │   │   ├─ emit UnwindingStarted(timestamp: 1734017313 [1.734e9], user: Bob: [0x4dBa461cA9342F4A6Cf942aBd7eacf8AE259108C], receiptTokens: 1000000000000000000000 [1e21], unwindingEpochs: 10, rewardWeight: 1200000000000000000000 [1.2e21])
    │   │   │   │   └─ ← [Stop]
    │   │   │   ├─ [23195] iusd::transfer(unwindingModule: [0x96d3F6c20EEd2697647F543fE6C08bC2Fbf39758], 1000000000000000000000 [1e21])
    │   │   │   │   ├─ emit Transfer(from: lockingController: [0x13aa49bAc059d709dd0a18D6bb63290076a702D7], to: unwindingModule: [0x96d3F6c20EEd2697647F543fE6C08bC2Fbf39758], value: 1000000000000000000000 [1e21])
    │   │   │   │   └─ ← [Return] true
    │   │   │   ├─ emit PositionRemoved(timestamp: 1734017313 [1.734e9], user: Bob: [0x4dBa461cA9342F4A6Cf942aBd7eacf8AE259108C], amount: 1000000000000000000000 [1e21], unwindingEpochs: 10)
    │   │   │   └─ ← [Stop]
    │   │   └─ ← [Stop]
    │   └─ ← [Return]
    ├─ [0] VM::stopPrank()
    │   └─ ← [Return]
    ├─ [4767] unwindingModule::balanceOf(Bob: [0x4dBa461cA9342F4A6Cf942aBd7eacf8AE259108C], 1734017313 [1.734e9]) [staticcall]
    │   └─ ← [Return] 909090909090909090909 [9.09e20]
    ├─ [0] console::log("Bob's initial balance in UnwindingModule:", 909090909090909090909 [9.09e20]) [staticcall]
    │   └─ ← [Stop]
    ├─ [0] VM::assertLt(909090909090909090909 [9.09e20], 910000000000000000000 [9.1e20], "Bob's balance should be heavily diluted") [staticcall]
    │   └─ ← [Return]
    └─ ← [Stop]

Suite result: ok. 2 passed; 0 failed; 0 skipped; finished in 12.79s (758.09ms CPU time)
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

Detailed remediation steps are provided in [REMEDIATION_STRATEGY.md](https://github.com/OmachokoYakubu/infinifi-orphan-shares-poc/blob/main/REMEDIATION_STRATEGY.md).

---
*Verified via forked-mainnet testing.*
