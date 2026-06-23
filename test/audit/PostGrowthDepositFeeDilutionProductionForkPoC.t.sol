// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";

import { SuperGovernor } from "../../src/SuperGovernor.sol";
import { SuperVaultAggregator } from "../../src/SuperVault/SuperVaultAggregator.sol";
import { SuperVault } from "../../src/SuperVault/SuperVault.sol";
import { SuperVaultStrategy } from "../../src/SuperVault/SuperVaultStrategy.sol";
import { ISuperVaultAggregator } from "../../src/interfaces/SuperVault/ISuperVaultAggregator.sol";
import { ISuperVaultStrategy } from "../../src/interfaces/SuperVault/ISuperVaultStrategy.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @notice Local Ethereum-fork reproduction using the deployed production
/// SuperGovernor, SuperVaultAggregator, and implementation bytecode.
contract PostGrowthDepositFeeDilutionProductionForkPoC is Test {
    address internal constant PRODUCTION_GOVERNOR = 0xB5396ef2bF8CA360cEB4166b77AFb2bed20e74d4;
    address internal constant PRODUCTION_AGGREGATOR = 0x10AC0b33e1C4501CF3ec1cB1AE51ebfdbd2d4698;
    address internal constant PRODUCTION_PPS_ORACLE = 0x366d88F03B8EF34eb49F32a927ff6e1609F694F2;
    address internal constant PRODUCTION_STRATEGY_IMPLEMENTATION = 0x770abd170404B8ed8182c04f380E567e647b457D;

    SuperGovernor internal governor;
    SuperVaultAggregator internal aggregator;
    MockERC20 internal asset;
    SuperVault internal vault;
    SuperVaultStrategy internal strategy;

    address internal manager;
    address internal firstUser;
    address internal lateUser;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_RPC_URL"));

        governor = SuperGovernor(PRODUCTION_GOVERNOR);
        aggregator = SuperVaultAggregator(PRODUCTION_AGGREGATOR);
        manager = makeAddr("forkManager");
        firstUser = makeAddr("firstUser");
        lateUser = makeAddr("lateUser");

        asset = new MockERC20("Fork Asset", "FORK", 18);

        uint256 minimumStaleness = governor.getMinStaleness();
        (address vaultAddress, address strategyAddress,) = aggregator.createVault(
            ISuperVaultAggregator.VaultCreationParams({
                asset: address(asset),
                name: "Production Fork Cohort Fee Vault",
                symbol: "PFCFV",
                mainManager: manager,
                secondaryManagers: new address[](0),
                minUpdateInterval: 1,
                maxStaleness: minimumStaleness,
                feeConfig: ISuperVaultStrategy.FeeConfig({
                    performanceFeeBps: 1_000,
                    managementFeeBps: 0,
                    recipient: manager
                })
            })
        );

        vault = SuperVault(vaultAddress);
        strategy = SuperVaultStrategy(payable(strategyAddress));

        bytes memory expectedStrategyCloneRuntime = abi.encodePacked(
            hex"363d3d373d3d3d363d73",
            PRODUCTION_STRATEGY_IMPLEMENTATION,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        assertEq(keccak256(strategyAddress.code), keccak256(expectedStrategyCloneRuntime));

        vm.prank(manager);
        aggregator.updateDeviationThreshold(strategyAddress, 1e18);

        asset.mint(firstUser, 100 ether);
        asset.mint(lateUser, 200 ether);

        vm.startPrank(firstUser);
        asset.approve(vaultAddress, type(uint256).max);
        vault.deposit(100 ether, firstUser);
        vm.stopPrank();

        asset.mint(strategyAddress, 100 ether);
        _forwardPPS(strategyAddress, 2 ether, minimumStaleness);

        assertEq(vault.totalSupply(), 100 ether);
        assertEq(asset.balanceOf(strategyAddress), 200 ether);
        assertEq(strategy.vaultHwmPps(), 1 ether);
    }

    function testFork_Control_SkimBeforeLateDepositCollectsTenAssets() public {
        address treasury = governor.getAddress(governor.TREASURY());
        uint256 strategyBefore = asset.balanceOf(address(strategy));
        uint256 managerBefore = asset.balanceOf(manager);
        uint256 treasuryBefore = asset.balanceOf(treasury);

        vm.prank(manager);
        strategy.skimPerformanceFee();

        assertEq(strategyBefore - asset.balanceOf(address(strategy)), 10 ether);
        assertEq(asset.balanceOf(manager) - managerBefore, 5 ether);
        assertEq(asset.balanceOf(treasury) - treasuryBefore, 5 ether);
    }

    function testFork_LateDepositIsChargedForPreDepositGain() public {
        uint256 lateUserAssetsBefore = asset.balanceOf(lateUser);

        vm.startPrank(lateUser);
        asset.approve(address(vault), type(uint256).max);
        uint256 lateShares = vault.deposit(200 ether, lateUser);
        vm.stopPrank();

        assertEq(lateShares, 100 ether);
        assertEq(asset.balanceOf(lateUser), lateUserAssetsBefore - 200 ether);
        assertEq(vault.convertToAssets(vault.balanceOf(lateUser)), 200 ether);

        address treasury = governor.getAddress(governor.TREASURY());
        uint256 strategyBefore = asset.balanceOf(address(strategy));
        uint256 managerBefore = asset.balanceOf(manager);
        uint256 treasuryBefore = asset.balanceOf(treasury);

        vm.prank(manager);
        strategy.skimPerformanceFee();

        uint256 totalFee = strategyBefore - asset.balanceOf(address(strategy));
        assertEq(totalFee, 20 ether, "late shares are included in historical PPS growth");
        assertEq(asset.balanceOf(manager) - managerBefore, 10 ether);
        assertEq(asset.balanceOf(treasury) - treasuryBefore, 10 ether);

        uint256 lateUserValueAfter = vault.convertToAssets(vault.balanceOf(lateUser));
        assertEq(lateUserValueAfter, 190 ether);
        assertEq(200 ether - lateUserValueAfter, 10 ether, "late user pays fee on pre-deposit gain");
    }

    function _forwardPPS(address strategyAddress, uint256 pps, uint256 minimumStaleness) internal {
        vm.warp(block.timestamp + minimumStaleness / 2 + 2);

        vm.mockCall(
            PRODUCTION_GOVERNOR,
            abi.encodeWithSelector(SuperGovernor.isUpkeepPaymentsEnabled.selector),
            abi.encode(false)
        );

        address[] memory strategies = new address[](1);
        strategies[0] = strategyAddress;
        uint256[] memory ppss = new uint256[](1);
        ppss[0] = pps;
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = block.timestamp;

        vm.prank(PRODUCTION_PPS_ORACLE);
        aggregator.forwardPPS(
            ISuperVaultAggregator.ForwardPPSArgs({
                strategies: strategies,
                ppss: ppss,
                timestamps: timestamps,
                updateAuthority: PRODUCTION_PPS_ORACLE
            })
        );

        vm.clearMockedCalls();
        assertEq(aggregator.getPPS(strategyAddress), pps);
    }
}
