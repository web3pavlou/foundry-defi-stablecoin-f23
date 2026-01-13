// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract MockSequencerUptimeFeed is AggregatorV3Interface {
    int256 private s_answer; // 0 = up, 1 = down
    uint256 private s_startedAt; // when this status started

    function setStatus(int256 answer, uint256 startedAt) external {
        s_answer = answer;
        s_startedAt = startedAt;
    }

    // --- V3 interface ---

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        // We only care about answer + startedAt in OracleLib
        return (1, s_answer, s_startedAt, block.timestamp, 1);
    }

    function decimals() external pure override returns (uint8) {
        return 0;
    }

    function description() external pure override returns (string memory) {
        return "Mock Sequencer Uptime";
    }

    function version() external pure override returns (uint256) {
        return 0;
    }

    function getRoundData(uint80) external pure override returns (uint80, int256, uint256, uint256, uint80) {
        revert("not implemented");
    }
}
