# Technical Deep Dive: Orphan Shares Dilution in UnwindingModule

## The Share-to-Asset Mapping Invariant

The `UnwindingModule` handles locked receipt tokens (like `iUSD`) during their unwinding period. The contract utilizes a share-accounting system similar to ERC4626 to distribute non-compounding yield and map shares to assets:

$$\text{User Asset Balance} = \text{User Shares} \times \frac{\text{totalReceiptTokens}}{\text{totalShares}}$$

Under standard operations, when a user enters the unwinding queue, receipt tokens are transferred to the module, and new shares are minted:

```solidity
    function startUnwinding(address _owner, uint256 _receiptTokens, uint32 _unwindingEpochs, uint256 _rewardWeight) external ... {
        ...
        uint256 newShares = _amountToShares(_receiptTokens);
        positions[id] = UnwindingPosition({
            shares: newShares,
            ...
        });
        totalShares += newShares;
        totalReceiptTokens += _receiptTokens;
        ...
    }
```

Since $\text{totalReceiptTokens}$ and $\text{totalShares}$ increase by equivalent ratios, the value per share remains 1:1.

---

## The Accounting Asymmetry (The "Orphan" Leak)

When rewards are deposited into the `UnwindingModule` via the `LockingController`, `totalShares` increases by the reward shares, and `totalReceiptTokens` increases by the reward amount:

```solidity
    function depositRewards(uint256 _amount) external onlyCoreRole(CoreRoles.LOCKED_TOKEN_MANAGER) {
        ...
        uint256 rewardShares = _amountToShares(_amount);
        point.rewardShares += rewardShares;
        ...
        totalShares += rewardShares;
        totalReceiptTokens += _amount;
        ...
    }
```

When a user exits their unwinding position via `cancelUnwinding` or `withdraw`, their balance (which includes both initial principal + accrued rewards) is computed and subtracted from `totalReceiptTokens`. 

**However**, `totalShares` is only decremented by the user's **initial** shares (`position.shares`), not their **current** shares (initial + reward shares):

```solidity
        uint256 userBalance = balanceOf(_owner, _startUnwindingTimestamp);
        ...
        delete positions[id];
        ...
        totalShares -= position.shares; // <--- The Logic Defect: Only subtracts initial shares!
        totalReceiptTokens -= userBalance; // Subtracts initial + reward assets!
```

### The Mathematical Divergence
Because `totalShares` is only decremented by `position.shares`, all the reward shares earned by the user are left behind as **orphan shares** inside the pool.

If Alice is the only user in the pool:
1. Alice starts unwinding with $1000$ receipt tokens $\rightarrow \text{totalShares} = 1000, \text{totalReceiptTokens} = 1000$.
2. $100$ rewards are deposited $\rightarrow \text{totalShares} = 1100, \text{totalReceiptTokens} = 1100$.
3. Alice exits. Her balance is calculated as:
   
   $$\text{Alice Balance} = 1100 \text{ receipt tokens}$$
   
4. Alice receives her $1100$ receipt tokens. The contract updates:
   - $\text{totalReceiptTokens} = 1100 - 1100 = 0$
   - $\text{totalShares} = 1100 - 1000 = 100 \text{ shares}$

The $100$ reward shares remain in `totalShares` as **orphan shares** with **zero** backing receipt tokens in the pool.

---

## Compounding Dilution for Future Depositors

When Bob enters the pool next with $1000$ receipt tokens:
1. Bob's shares are computed using `_amountToShares(1000)`:
   
   $$\text{Bob's Shares} = 1000 \text{ shares (since totalReceiptTokens is 0, shares are minted 1:1)}$$
   
2. The pool updates to:
   - $\text{totalReceiptTokens} = 1000$
   - $\text{totalShares} = 1000 + 100 \text{ (Alice's orphan shares)} = 1100 \text{ shares}$
3. If Bob immediately cancels or withdraws, his balance is:
   
   $$\text{Bob's Balance} = 1000 \times \frac{1000}{1100} = 909.09 \text{ receipt tokens}$$

Bob immediately loses **9.09% of his principal** to the orphan shares. As more rewards are distributed and more users exit, this dilution compounds indefinitely, eventually rendering the unwinding module completely insolvent and destroying all future depositor funds.
