// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {EpochLib} from "@libraries/EpochLib.sol";

contract SymbolicEpochLib is Test {
    // A symbolic test for EpochLib.epochToTimestamp and epoch round-trip
    function check_epochRoundTrip(uint256 epochNum) public pure {
        // Assume epoch number is within reasonable bounds to avoid overflow
        vm.assume(epochNum < 1e18);

        uint256 ts = EpochLib.epochToTimestamp(epochNum);
        uint256 calculatedEpoch = EpochLib.epoch(ts);

        assert(calculatedEpoch == epochNum);
    }
}
