// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/AgentBountyBoard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock CLAWD token for testing
contract MockCLAWD2 is ERC20 {
    constructor() ERC20("CLAWD", "CLAWD") {
        _mint(msg.sender, 1_000_000 ether);
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title AgentBountyBoard Edge Case Tests
 * @notice Additional tests for edge cases and revert conditions
 * @author Kyro (kyro-agent)
 */
contract AgentBountyBoardEdgeTest is Test {
    AgentBountyBoard public board;
    MockCLAWD2 public clawd;
    
    address poster = address(0x1);
    address agent = address(0x2);
    address agent2 = address(0x3);
    address random = address(0x4);
    
    function setUp() public {
        clawd = new MockCLAWD2();
        board = new AgentBountyBoard(address(clawd));
        
        // Fund accounts
        clawd.mint(poster, 10_000 ether);
        clawd.mint(agent, 1_000 ether);
        clawd.mint(agent2, 1_000 ether);
    }

    // ═══════════════════════════════════════════
    //         CLAIM EDGE CASES
    // ═══════════════════════════════════════════

    function test_claimJob_revertAlreadyClaimed() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test job", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        // First agent claims
        vm.prank(agent);
        board.claimJob(0, 21548);

        // Second agent tries to claim same job
        vm.prank(agent2);
        vm.expectRevert("Job not open");
        board.claimJob(0, 21549);
    }

    function test_claimJob_revertJobDoesNotExist() public {
        vm.prank(agent);
        vm.expectRevert(); // Array out of bounds
        board.claimJob(999, 21548);
    }

    // ═══════════════════════════════════════════
    //         APPROVE/DISPUTE EDGE CASES
    // ═══════════════════════════════════════════

    function test_approveWork_revertNotSubmitted() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.prank(agent);
        board.claimJob(0, 21548);

        // Try to approve before work submitted
        vm.prank(poster);
        vm.expectRevert("Job not submitted");
        board.approveWork(0, 90);
    }

    function test_approveWork_revertNotPoster() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.prank(agent);
        board.claimJob(0, 21548);

        vm.prank(agent);
        board.submitWork(0, "ipfs://work");

        // Random address tries to approve
        vm.prank(random);
        vm.expectRevert("Only poster can approve");
        board.approveWork(0, 90);
    }

    function test_disputeWork_revertNotSubmitted() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.prank(agent);
        board.claimJob(0, 21548);

        // Try to dispute before work submitted
        vm.prank(poster);
        vm.expectRevert("Job not submitted");
        board.disputeWork(0);
    }

    function test_disputeWork_revertNotPoster() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.prank(agent);
        board.claimJob(0, 21548);

        vm.prank(agent);
        board.submitWork(0, "ipfs://work");

        // Random address tries to dispute
        vm.prank(random);
        vm.expectRevert("Only poster can dispute");
        board.disputeWork(0);
    }

    // ═══════════════════════════════════════════
    //         CANCEL EDGE CASES
    // ═══════════════════════════════════════════

    function test_cancelJob_revertAlreadyClaimed() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.prank(agent);
        board.claimJob(0, 21548);

        // Try to cancel after claim
        vm.prank(poster);
        vm.expectRevert("Job not open");
        board.cancelJob(0);
    }

    function test_cancelJob_revertNotPoster() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        // Random address tries to cancel
        vm.prank(random);
        vm.expectRevert("Only poster can cancel");
        board.cancelJob(0);
    }

    // ═══════════════════════════════════════════
    //         EXPIRE EDGE CASES
    // ═══════════════════════════════════════════

    function test_expireJob_revertNotClaimed() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        // Try to expire unclaimed job
        vm.warp(block.timestamp + 1000);
        vm.expectRevert("Job not in claimed state");
        board.expireJob(0);
    }

    function test_expireJob_revertDeadlineNotPassed() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.prank(agent);
        board.claimJob(0, 21548);

        // Try to expire before deadline
        vm.warp(block.timestamp + 100);
        vm.expectRevert("Deadline not yet passed");
        board.expireJob(0);
    }

    // ═══════════════════════════════════════════
    //         SUBMIT WORK EDGE CASES
    // ═══════════════════════════════════════════

    function test_submitWork_revertNotAssignedAgent() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.prank(agent);
        board.claimJob(0, 21548);

        // Different agent tries to submit
        vm.prank(agent2);
        vm.expectRevert("Only assigned agent");
        board.submitWork(0, "ipfs://fake");
    }

    function test_submitWork_revertEmptyURI() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.prank(agent);
        board.claimJob(0, 21548);

        vm.prank(agent);
        vm.expectRevert("Submission URI required");
        board.submitWork(0, "");
    }

    // ═══════════════════════════════════════════
    //         RECLAIM EDGE CASES
    // ═══════════════════════════════════════════

    function test_reclaimWork_revertWrongAgent() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.prank(agent);
        board.claimJob(0, 21548);

        vm.prank(agent);
        board.submitWork(0, "ipfs://work");

        // Wait past reclaim period
        vm.warp(block.timestamp + 1000);

        // Wrong agent tries to reclaim
        vm.prank(agent2);
        vm.expectRevert("Only assigned agent");
        board.reclaimWork(0);
    }

    function test_reclaimWork_revertNotSubmitted() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.prank(agent);
        board.claimJob(0, 21548);

        // Try reclaim without submitting
        vm.warp(block.timestamp + 1000);
        vm.prank(agent);
        vm.expectRevert("Job not submitted");
        board.reclaimWork(0);
    }

    // ═══════════════════════════════════════════
    //         RATING EDGE CASES
    // ═══════════════════════════════════════════

    function test_approveWork_revertRatingTooHigh() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.prank(agent);
        board.claimJob(0, 21548);

        vm.prank(agent);
        board.submitWork(0, "ipfs://work");

        // Try to rate > 100
        vm.prank(poster);
        vm.expectRevert("Rating must be 0-100");
        board.approveWork(0, 101);
    }

    function test_approveWork_zeroRatingAllowed() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.prank(agent);
        board.claimJob(0, 21548);

        vm.prank(agent);
        board.submitWork(0, "ipfs://work");

        // Zero rating should be allowed (poor quality but delivered)
        vm.prank(poster);
        board.approveWork(0, 0);

        (uint256 completed, , , uint256 avgRating) = board.getAgentStats(agent);
        assertEq(completed, 1);
        assertEq(avgRating, 0);
    }
}
