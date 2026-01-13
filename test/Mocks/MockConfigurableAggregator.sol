//SPDX-License-Identifier:MIT

pragma solidity ^0.8.29;

import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract MockConfigurableAggregator is AggregatorV3Interface {
    uint8 private immutable i_decimals;

    uint80 internal s_roundId;
    int256 internal s_answer;
    uint256 internal s_startedAt;
    uint256 internal s_updatedAt;
    uint80 internal s_answeredInRound;

    constructor(
        uint8 decimals_
    ) {
        i_decimals = decimals_;
    }

    function setRoundData(
        uint80 roundId_,
        int256 answer_,
        uint256 startedAt_,
        uint256 updatedAt_,
        uint80 answeredInRound_
    ) external {
        s_roundId = roundId_;
        s_answer = answer_;
        s_startedAt = startedAt_;
        s_updatedAt = updatedAt_;
        s_answeredInRound = answeredInRound_;
    }

    function decimals() external view override returns (uint8) {
        return i_decimals;
    }

    function description() external pure override returns (string memory) {
        return "configurable-mock";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80
    ) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (s_roundId, s_answer, s_startedAt, s_updatedAt, s_answeredInRound);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (s_roundId, s_answer, s_startedAt, s_updatedAt, s_answeredInRound);
    }
}
