// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { SuperGovernor } from "../../src/SuperGovernor.sol";
import { SuperVaultAggregator } from "../../src/SuperVault/SuperVaultAggregator.sol";
import { SuperVault } from "../../src/SuperVault/SuperVault.sol";
import { SuperVaultStrategy } from "../../src/SuperVault/SuperVaultStrategy.sol";
import { SuperVaultEscrow } from "../../src/SuperVault/SuperVaultEscrow.sol";
import { ECDSAPPSOracle } from "../../src/oracles/ECDSAPPSOracle.sol";
import { ISuperVaultAggregator } from "../../src/interfaces/SuperVault/ISuperVaultAggregator.sol";
import { ISuperVaultStrategy } from "../../src/interfaces/SuperVault/ISuperVaultStrategy.sol";
import { IECDSAPPSOracle } from "../../src/interfaces/oracles/IECDSAPPSOracle.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @notice Demonstrates that a depositor entering after PPS growth is charged
/// performance fees on growth that occurred before their deposit.
contract PostGrowthDepositFeeDilutionPoC is Test {
    using MessageHashUtils for bytes32;

    uint256 internal constant VALIDATOR_1_KEY = 0xA11CE;
    uint256 internal constant VALIDATOR_2_KEY = 0xB0B;

    SuperGovernor internal governor;
    SuperVaultAggregator internal aggregator;
    ECDSAPPSOracle internal oracle;
    MockERC20 internal asset;
    SuperVault internal vault;
    SuperVaultStrategy internal strategy;

    address internal manager;
    address internal firstUser;
    address internal lateUser;

    function setUp() public {
        manager = makeAddr("manager");
        firstUser = makeAddr("firstUser");
        lateUser = makeAddr("lateUser");

        governor = new SuperGovernor(
            address(this),
            address(this),
            address(this),
            address(this),
            address(this),
            address(this),
            makeAddr("treasury"),
            false
        );

        address vaultImpl = address(new SuperVault(address(governor)));
        address strategyImpl = address(new SuperVaultStrategy(address(governor)));
        address escrowImpl = address(new SuperVaultEscrow());

        aggregator = new SuperVaultAggregator(address(governor), vaultImpl, strategyImpl, escrowImpl);
        governor.setAddress(governor.SUPER_VAULT_AGGREGATOR(), address(aggregator));

        asset = new MockERC20("Asset", "ASSET", 18);

        (address vaultAddress, address strategyAddress,) = aggregator.createVault(
            ISuperVaultAggregator.VaultCreationParams({
                asset: address(asset),
                name: "Fee Cohort Vault",
                symbol: "FCV",
                mainManager: manager,
                secondaryManagers: new address[](0),
                minUpdateInterval: 5,
                maxStaleness: 300,
                feeConfig: ISuperVaultStrategy.FeeConfig({
                    performanceFeeBps: 1_000,
                    managementFeeBps: 0,
                    recipient: manager
                })
            })
        );

        vault = SuperVault(vaultAddress);
        strategy = SuperVaultStrategy(payable(strategyAddress));

        vm.prank(manager);
        aggregator.updateDeviationThreshold(address(strategy), 1e18);

        oracle = new ECDSAPPSOracle(address(governor), "SuperformOraclePPS", "1");

        address[] memory validators = new address[](2);
        validators[0] = vm.addr(VALIDATOR_1_KEY);
        validators[1] = vm.addr(VALIDATOR_2_KEY);
        bytes[] memory publicKeys = new bytes[](2);

        governor.setValidatorConfig(1, validators, publicKeys, 2, "");
        governor.proposeActivePPSOracle(address(oracle));
        vm.warp(block.timestamp + 7 days);
        governor.executeActivePPSOracleChange();
        _updatePPS(1 ether);

        asset.mint(firstUser, 100 ether);
        asset.mint(lateUser, 200 ether);

        vm.startPrank(firstUser);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(100 ether, firstUser);
        vm.stopPrank();

        asset.mint(address(strategy), 100 ether);
        _updatePPS(2 ether);

        assertEq(vault.totalSupply(), 100 ether);
        assertEq(asset.balanceOf(address(strategy)), 200 ether);
        assertEq(strategy.vaultHwmPps(), 1 ether);
    }

    function test_Control_SkimBeforeLateDepositChargesOnlyExistingGain() public {
        uint256 strategyBefore = asset.balanceOf(address(strategy));

        vm.prank(manager);
        strategy.skimPerformanceFee();

        uint256 totalFee = strategyBefore - asset.balanceOf(address(strategy));
        assertEq(totalFee, 10 ether, "10% fee on the original cohort's 100-asset gain");
    }

    function test_PoC_LateDepositDoublesFeeBaseWithoutAddingProfit() public {
        vm.startPrank(lateUser);
        asset.approve(address(vault), type(uint256).max);
        uint256 lateShares = vault.deposit(200 ether, lateUser);
        vm.stopPrank();

        assertEq(lateShares, 100 ether);
        assertEq(vault.totalSupply(), 200 ether);
        assertEq(asset.balanceOf(address(strategy)), 400 ether);

        uint256 lateUserValueBeforeSkim = vault.convertToAssets(vault.balanceOf(lateUser));
        assertEq(lateUserValueBeforeSkim, 200 ether);

        uint256 strategyBefore = asset.balanceOf(address(strategy));
        vm.prank(manager);
        strategy.skimPerformanceFee();

        uint256 totalFee = strategyBefore - asset.balanceOf(address(strategy));

        assertEq(totalFee, 20 ether, "late supply is incorrectly included in historical profit");

        uint256 lateUserValueAfterSkim = vault.convertToAssets(vault.balanceOf(lateUser));
        assertEq(lateUserValueAfterSkim, 190 ether);
        assertEq(
            lateUserValueBeforeSkim - lateUserValueAfterSkim,
            10 ether,
            "late depositor pays fee on gain earned before joining"
        );
    }

    function test_PoC_DepositCanBeSandwichedBetweenGrowthAndPermissionlessEconomicRealization() public {
        vm.startPrank(lateUser);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(200 ether, lateUser);
        vm.stopPrank();

        uint256 firstUserBefore = vault.convertToAssets(vault.balanceOf(firstUser));
        uint256 lateUserBefore = vault.convertToAssets(vault.balanceOf(lateUser));

        vm.prank(manager);
        strategy.skimPerformanceFee();

        uint256 firstUserAfter = vault.convertToAssets(vault.balanceOf(firstUser));
        uint256 lateUserAfter = vault.convertToAssets(vault.balanceOf(lateUser));

        assertEq(firstUserBefore - firstUserAfter, 10 ether);
        assertEq(lateUserBefore - lateUserAfter, 10 ether);
        assertEq(
            firstUserAfter + lateUserAfter,
            380 ether,
            "the 20-asset fee is socialized equally per share"
        );
    }

    function _updatePPS(uint256 newPPS) internal {
        vm.warp(block.timestamp + 10);
        uint256 timestamp = block.timestamp;
        bytes[] memory proofs = _createProofs(address(strategy), newPPS, timestamp);
        oracle.updatePPS(_singleUpdateArgs(address(strategy), newPPS, timestamp, proofs));
        assertEq(aggregator.getPPS(address(strategy)), newPPS);
    }

    function _createProofs(
        address strategy_,
        uint256 pps,
        uint256 timestamp
    ) internal returns (bytes[] memory proofs) {
        bytes32 structHash = keccak256(
            abi.encodePacked(
                oracle.UPDATE_PPS_TYPEHASH(),
                strategy_,
                pps,
                timestamp,
                oracle.noncePerStrategy(strategy_)
            )
        );
        bytes32 digest = oracle.domainSeparator().toTypedDataHash(structHash);

        uint256 firstKey = VALIDATOR_1_KEY;
        uint256 secondKey = VALIDATOR_2_KEY;
        if (vm.addr(firstKey) > vm.addr(secondKey)) {
            (firstKey, secondKey) = (secondKey, firstKey);
        }

        proofs = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(firstKey, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(secondKey, digest);
        proofs[0] = abi.encodePacked(r1, s1, v1);
        proofs[1] = abi.encodePacked(r2, s2, v2);
    }

    function _singleUpdateArgs(
        address strategy_,
        uint256 pps,
        uint256 timestamp,
        bytes[] memory proofs
    ) internal pure returns (IECDSAPPSOracle.UpdatePPSArgs memory args) {
        address[] memory strategies = new address[](1);
        strategies[0] = strategy_;

        bytes[][] memory proofsArray = new bytes[][](1);
        proofsArray[0] = proofs;

        uint256[] memory ppss = new uint256[](1);
        ppss[0] = pps;

        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = timestamp;

        args = IECDSAPPSOracle.UpdatePPSArgs({
            strategies: strategies,
            proofsArray: proofsArray,
            ppss: ppss,
            timestamps: timestamps
        });
    }
}
