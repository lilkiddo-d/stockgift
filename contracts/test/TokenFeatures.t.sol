// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";
import {IGiftVault} from "../src/interfaces/IStockgift.sol";
import {MockERC20, FeeOnTransferERC20} from "./mocks/Mocks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice $GIFT integration: everything is off until setProjectToken; then tiers and staking work.
contract TokenFeaturesTest is BaseTest {
    address internal staker1 = makeAddr("staker1");
    address internal staker2 = makeAddr("staker2");

    function _enableToken() internal {
        vm.prank(admin);
        hooks.setProjectToken(address(giftToken));
        giftToken.mint(staker1, 100_000e18);
        giftToken.mint(staker2, 100_000e18);
        giftToken.mint(alice, 100_000e18);
        vm.prank(staker1);
        giftToken.approve(address(feeCollector), type(uint256).max);
        vm.prank(staker2);
        giftToken.approve(address(feeCollector), type(uint256).max);
        vm.prank(alice);
        giftToken.approve(address(feeCollector), type(uint256).max);
    }

    function test_tokenUnset_everythingDisabled() public {
        assertEq(hooks.projectToken(), address(0));
        assertFalse(hooks.isFeeExempt(alice));
        assertFalse(hooks.hasPremium(alice));
        assertEq(hooks.tierBalance(alice), 0);
        vm.prank(staker1);
        vm.expectRevert(FeeCollector.TokenNotSet.selector);
        feeCollector.stake(1);
        // protocol fully works without it
        uint256 id = _create(_params(100e6));
        assertEq(vault.getGift(id).amount, _net(100e6));
    }

    function test_setProjectToken_onceAndValidated() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        hooks.setProjectToken(address(giftToken));

        vm.startPrank(admin);
        vm.expectRevert(ProjectTokenHooks.InvalidAddress.selector);
        hooks.setProjectToken(address(0));
        vm.expectRevert(ProjectTokenHooks.InvalidAddress.selector);
        hooks.setProjectToken(makeAddr("eoa"));
        hooks.setProjectToken(address(giftToken));
        vm.expectRevert(ProjectTokenHooks.AlreadySet.selector);
        hooks.setProjectToken(address(usdg));
        vm.expectRevert(ProjectTokenHooks.AlreadySet.selector);
        hooks.setFeeCollector(address(1));
        vm.stopPrank();
        assertEq(hooks.projectToken(), address(giftToken));
    }

    function test_feeExemptTier_zeroFees() public {
        _enableToken();
        vm.prank(alice);
        feeCollector.stake(10_000e18);
        assertFalse(hooks.isFeeExempt(alice)); // min stake age
        vm.warp(block.timestamp + 1 days);
        assertTrue(hooks.isFeeExempt(alice));
        assertTrue(hooks.hasPremium(alice));
        uint256 id = _create(_params(100e6));
        assertEq(vault.getGift(id).amount, 100e6);
    }

    function test_walletBalanceTier_optional() public {
        _enableToken();
        assertEq(hooks.tierBalance(alice), 0);
        vm.prank(admin);
        hooks.setTiers(1e18, 50_000e18, 0, true);
        assertEq(hooks.tierBalance(alice), 100_000e18);
        assertTrue(hooks.isFeeExempt(alice));
        vm.prank(admin);
        hooks.setTiers(0, 0, 0, true);
        assertFalse(hooks.isFeeExempt(alice));
        assertFalse(hooks.hasPremium(alice));
    }

    function test_stakersShareFees() public {
        _enableToken();
        vm.prank(staker1);
        feeCollector.stake(1_000e18);
        vm.prank(staker2);
        feeCollector.stake(3_000e18);

        _create(_params(1_000e6)); // fee 5 USDG -> 2.5 to stakers, 2.5 treasury
        assertEq(feeCollector.treasuryBalance(address(usdg)), 2.5e6);
        assertEq(feeCollector.earned(staker1, address(usdg)), 0.625e6);
        assertEq(feeCollector.earned(staker2, address(usdg)), 1.875e6);

        vm.prank(staker1);
        feeCollector.claimRewards();
        assertEq(usdg.balanceOf(staker1), 0.625e6);
        assertEq(feeCollector.earned(staker1, address(usdg)), 0);

        // staker2 unstakes half; rewards are settled, not lost
        vm.prank(staker2);
        feeCollector.unstake(1_500e18);
        assertEq(feeCollector.earned(staker2, address(usdg)), 1.875e6);
        assertEq(giftToken.balanceOf(staker2), 100_000e18 - 1_500e18);

        _create(_params(1_000e6)); // 2.5 to stakers split 1000:1500
        assertEq(feeCollector.earned(staker1, address(usdg)), 1e6);
        assertEq(feeCollector.earned(staker2, address(usdg)), 1.875e6 + 1.5e6);

        vm.prank(staker2);
        feeCollector.unstake(1_500e18);
        assertEq(feeCollector.stakedSince(staker2), 0);
        vm.prank(staker2);
        feeCollector.claimRewards();
        assertEq(usdg.balanceOf(staker2), 3.375e6);
    }

    function test_nonRewardTokenFees_goToTreasury() public {
        _enableToken();
        vm.prank(staker1);
        feeCollector.stake(1_000e18);
        IGiftVault.CreateParams memory p = _params(100e18);
        p.token = address(tsla);
        p.targetToken = address(0);
        _create(p);
        assertEq(feeCollector.treasuryBalance(address(tsla)), 0.5e18);
        assertEq(feeCollector.earned(staker1, address(tsla)), 0);
    }

    function test_noStakers_allToTreasury_andWithdraw() public {
        _create(_params(1_000e6));
        assertEq(feeCollector.treasuryBalance(address(usdg)), 5e6);
        address treasury = makeAddr("treasury");
        vm.startPrank(admin);
        vm.expectRevert(FeeCollector.InsufficientTreasury.selector);
        feeCollector.withdrawTreasury(address(usdg), treasury, 6e6);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        feeCollector.withdrawTreasury(address(usdg), address(0), 1);
        feeCollector.withdrawTreasury(address(usdg), treasury, 5e6);
        vm.stopPrank();
        assertEq(usdg.balanceOf(treasury), 5e6);
    }

    function test_feeCollector_adminAndErrors() public {
        _enableToken();
        vm.startPrank(admin);
        vm.expectRevert(FeeCollector.InvalidToken.selector);
        feeCollector.addRewardToken(address(usdg)); // dup
        vm.expectRevert(FeeCollector.InvalidToken.selector);
        feeCollector.addRewardToken(address(giftToken)); // staking token
        vm.expectRevert(FeeCollector.InvalidToken.selector);
        feeCollector.addRewardToken(address(0));
        for (uint256 i; i < 9; ++i) {
            feeCollector.addRewardToken(address(new MockERC20("r", "r", 18)));
        }
        vm.expectRevert(FeeCollector.TooManyRewardTokens.selector);
        feeCollector.addRewardToken(address(tsla));
        assertEq(feeCollector.rewardTokenCount(), 10);
        vm.expectRevert(FeeCollector.InvalidShare.selector);
        feeCollector.setStakerShareBps(10_001);
        feeCollector.setStakerShareBps(10_000);
        vm.stopPrank();

        vm.startPrank(staker1);
        vm.expectRevert(FeeCollector.ZeroAmount.selector);
        feeCollector.stake(0);
        vm.expectRevert(FeeCollector.ZeroAmount.selector);
        feeCollector.unstake(0);
        vm.expectRevert(FeeCollector.InsufficientStake.selector);
        feeCollector.unstake(1);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), feeCollector.NOTIFIER_ROLE()
            )
        );
        feeCollector.notifyFee(address(usdg), 1);

        vm.prank(guardian);
        feeCollector.pause();
        vm.prank(staker1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        feeCollector.stake(1);
        vm.prank(guardian);
        feeCollector.unpause();

        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        new FeeCollector(address(0), guardian, address(hooks));
        vm.expectRevert(ProjectTokenHooks.InvalidAddress.selector);
        new ProjectTokenHooks(address(0), 0, 0);
    }

    function test_stake_rejectsFeeOnTransferProjectToken() public {
        ProjectTokenHooks h = new ProjectTokenHooks(admin, 1, 1);
        FeeCollector fc = new FeeCollector(admin, guardian, address(h));
        FeeOnTransferERC20 fot = new FeeOnTransferERC20();
        vm.prank(admin);
        h.setProjectToken(address(fot));
        fot.mint(alice, 10e18);
        vm.startPrank(alice);
        fot.approve(address(fc), type(uint256).max);
        vm.expectRevert(FeeCollector.InvalidToken.selector);
        fc.stake(1e18);
        vm.stopPrank();
        assertEq(h.tierBalance(alice), 0); // no fee collector linked
    }

    function testFuzz_rewardsConserved(uint96 s1, uint96 s2, uint64 fee1, uint64 fee2) public {
        s1 = uint96(bound(s1, 1e18, 50_000e18));
        s2 = uint96(bound(s2, 1e18, 50_000e18));
        fee1 = uint64(bound(fee1, 1, 1e15));
        fee2 = uint64(bound(fee2, 1, 1e15));
        _enableToken();
        vm.prank(staker1);
        feeCollector.stake(s1);
        usdg.mint(address(feeCollector), fee1);
        vm.prank(address(vault));
        feeCollector.notifyFee(address(usdg), fee1);
        vm.prank(staker2);
        feeCollector.stake(s2);
        usdg.mint(address(feeCollector), fee2);
        vm.prank(address(vault));
        feeCollector.notifyFee(address(usdg), fee2);

        uint256 owed = feeCollector.earned(staker1, address(usdg)) + feeCollector.earned(staker2, address(usdg));
        uint256 treasury = feeCollector.treasuryBalance(address(usdg));
        assertLe(owed + treasury, uint256(fee1) + fee2);
        assertGe(owed + treasury + 4, uint256(fee1) + fee2); // rounding dust only
        vm.prank(staker1);
        feeCollector.claimRewards();
        vm.prank(staker2);
        feeCollector.claimRewards();
        assertGe(usdg.balanceOf(address(feeCollector)), treasury);
    }
}
