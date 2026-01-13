//SPDX-License-Identifier:MIT
pragma solidity ^0.8.29;

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Test } from "forge-std/Test.sol";
import { DSCEngine } from "../../../src/DSCEngine.sol";
import { DWebThreePavlouStableCoin } from "../../../src/DWebThreePavlouStableCoin.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { MockV3Aggregator } from "../../Mocks/MockV3Aggregator.sol";
import { Vm } from "forge-std/Vm.sol";

contract ContinueOnRevertHandler is Test {
    using EnumerableSet for EnumerableSet.AddressSet;

    DSCEngine public immutable dscEngine;
    DWebThreePavlouStableCoin public immutable dsc;

    ERC20Mock public immutable weth;
    ERC20Mock public immutable wbtc;

    MockV3Aggregator public immutable ethUsdPriceFeed;
    MockV3Aggregator public immutable btcUsdPriceFeed;

    // Actors
    EnumerableSet.AddressSet private s_actors;

    // Soft caps (not strict “protocol assumptions”, just to avoid pointless overflows)
    uint256 public constant MAX_WHOLE_TOKENS = 1_000_000; // 1M units max

    bytes32 private constant LIQUIDATION_SIG = keccak256("Liquidation(address,address,address,uint256,uint256)");

    // Ghost flags / counters
    bool public mintedWithPoorHealthFactor;
    uint256 public mintSuccessCount;

    bool public liquidationDidNotImproveHf;
    uint256 public liquidationSuccessCount;

    // Track minted debt per actor WITHOUT calling oracle-dependent getters
    mapping(address => uint256) private s_trackedDebt;

    constructor(DSCEngine _dscEngine, DWebThreePavlouStableCoin _dsc) {
        dscEngine = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(weth)));
        btcUsdPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(wbtc)));
    }

    // -------------------------
    // Actor helpers
    // -------------------------
    function actorLength() external view returns (uint256) {
        return s_actors.length();
    }

    function actorAt(uint256 i) external view returns (address) {
        return s_actors.at(i);
    }

    function trackedDebt(address a) external view returns (uint256) {
        return s_trackedDebt[a];
    }

    function _addActor(address a) internal {
        if (a != address(0)) s_actors.add(a);
    }

    function _pickActor(uint256 seed) internal view returns (address) {
        uint256 len = s_actors.length();
        if (len == 0) return address(0);
        return s_actors.at(seed % len);
    }

    function _pickVictimNotSelf(uint256 seed, address self) internal view returns (address) {
        uint256 len = s_actors.length();
        if (len == 0) return address(0);

        address v = s_actors.at(seed % len);
        if (v == self) {
            if (len == 1) return address(0);
            v = s_actors.at((seed + 1) % len);
        }
        return v;
    }

    function _getCollateralFromSeed(uint256 seed) internal view returns (ERC20Mock) {
        return (seed % 2 == 0) ? weth : wbtc;
    }

    function _maxTokenAmount(address token) internal view returns (uint256) {
        uint8 dec = dscEngine.getTokenDecimals(token);
        return MAX_WHOLE_TOKENS * (10 ** uint256(dec));
    }

    function _tryHealthFactor(address user) internal view returns (bool ok, uint256 hf) {
        try dscEngine.getHealthFactor(user) returns (uint256 v) {
            return (true, v);
        } catch {
            return (false, 0);
        }
    }

    // -------------------------
    // Actions (targeted by invariant fuzzer)
    // -------------------------

    function mintAndDepositCollateral(uint256 collateralSeed, uint256 amountCollateral) external {
        _addActor(msg.sender);

        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxAmt = _maxTokenAmount(address(collateral));
        amountCollateral = _bound(amountCollateral, 0, maxAmt);
        if (amountCollateral == 0) return;

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dscEngine), amountCollateral);
        // may revert (amount 0, protocol checks, etc.) — that’s fine in ContinueOnRevert
        dscEngine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function mintDsc(uint256 amountDscToMint) external {
        _addActor(msg.sender);

        // don’t only mint from msg.sender (often has no collateral). pick an existing actor
        address actor = _pickActor(uint256(uint160(msg.sender)));
        if (actor == address(0)) return;

        // keep it wide but not insane
        amountDscToMint = _bound(amountDscToMint, 1, type(uint96).max);

        vm.startPrank(actor);
        try dscEngine.mintDsc(amountDscToMint) {
            mintSuccessCount++;
            s_trackedDebt[actor] += amountDscToMint;

            // detect “mint succeeded but HF ended < min”
            (bool ok, uint256 hf) = _tryHealthFactor(actor);
            if (ok) {
                uint256 minHf = dscEngine.getMinHealthFactor();
                if (hf < minHf) mintedWithPoorHealthFactor = true;
            }
        } catch {
            // ok
        }
        vm.stopPrank();
    }

    function burnDsc(uint256 amountDsc) external {
        _addActor(msg.sender);

        uint256 bal = dsc.balanceOf(msg.sender);
        amountDsc = _bound(amountDsc, 0, bal);

        vm.startPrank(msg.sender);
        dsc.approve(address(dscEngine), amountDsc);
        try dscEngine.burnDsc(amountDsc) {
            // track only if burn succeeded
            uint256 prev = s_trackedDebt[msg.sender];
            s_trackedDebt[msg.sender] = (amountDsc >= prev) ? 0 : (prev - amountDsc);
        } catch {
            // ok
        }
        vm.stopPrank();
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) external {
        _addActor(msg.sender);

        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxBal = dscEngine.getCollateralBalanceOfUser(msg.sender, address(collateral));
        amountCollateral = _bound(amountCollateral, 0, maxBal);

        vm.startPrank(msg.sender);
        try dscEngine.redeemCollateral(address(collateral), amountCollateral) {
        // ok
        }
            catch {
            // ok
        }
        vm.stopPrank();
    }

    function transferDsc(uint256 amountDsc, address to) external {
        if (to == address(0)) to = address(1);
        _addActor(msg.sender);
        _addActor(to);

        uint256 bal = dsc.balanceOf(msg.sender);
        amountDsc = _bound(amountDsc, 0, bal);

        vm.prank(msg.sender);
        dsc.transfer(to, amountDsc);
    }

    function liquidate(uint256 collateralSeed, uint256 victimSeed, uint256 debtToCover) external {
        _addActor(msg.sender);

        address victim = _pickVictimNotSelf(victimSeed, msg.sender);
        if (victim == address(0)) return;

        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        uint256 liquidatorBal = dsc.balanceOf(msg.sender);
        debtToCover = _bound(debtToCover, 0, liquidatorBal);
        if (debtToCover == 0) return;

        (bool okBefore, uint256 hfBefore) = _tryHealthFactor(victim);

        vm.startPrank(msg.sender);
        dsc.approve(address(dscEngine), debtToCover);

        vm.recordLogs();
        try dscEngine.liquidate(address(collateral), victim, debtToCover) {
            liquidationSuccessCount++;

            // update ghost debt using emitted event
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i = 0; i < logs.length; i++) {
                if (
                    logs[i].emitter == address(dscEngine) && logs[i].topics.length > 0
                        && logs[i].topics[0] == LIQUIDATION_SIG
                ) {
                    //data = abi.encode(debtBurned,collateralSeized)
                    (uint256 debtBurned,) = abi.decode(logs[i].data, (uint256, uint256));

                    uint256 prev = s_trackedDebt[victim];
                    s_trackedDebt[victim] = (debtBurned >= prev) ? 0 : (prev - debtBurned);
                }
            }

            (bool okAfter, uint256 hfAfter) = _tryHealthFactor(victim);
            if (okBefore && okAfter) {
                if (hfAfter <= hfBefore) liquidationDidNotImproveHf = true;
            }
        } catch {
            // ok
        }

        vm.stopPrank();
    }

    //known issue:Solvency is not guaranteed under rapid drawdowns (crash risk).
    //So we assume oracle is valid and prices are bounded to save "runs"
    function updateCollateralPrice(uint256 collateralSeed, uint256 scaleBps) external {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        MockV3Aggregator feed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(collateral)));
        if (s_actors.length() == 0) return;

        (, int256 cur,,,) = feed.latestRoundData();
        if (cur <= 0) return;

        // 500..20_000 => 0.05x .. 2.0x
        scaleBps = _bound(scaleBps, 500, 20_000);

        int256 next = (cur * int256(uint256(scaleBps))) / 10_000;
        if (next <= 0) next = 1; // keep oracle valid

        feed.updateAnswer(next);
    }
}
