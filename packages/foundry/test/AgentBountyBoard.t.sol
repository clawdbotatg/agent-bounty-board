// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/AgentBountyBoard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock CLAWD token for testing
contract MockCLAWD is ERC20 {
    constructor() ERC20("CLAWD", "CLAWD") {
        _mint(msg.sender, 1_000_000 ether);
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AgentBountyBoardTest is Test {
    AgentBountyBoard public board;
    MockCLAWD public clawd;
    
    address poster = address(0x1);
    address agent = address(0x2);
    address agent2 = address(0x3);
    
    function setUp() public {
        clawd = new MockCLAWD();
        board = new AgentBountyBoard(address(clawd));
        
        // Fund poster and agent
        clawd.mint(poster, 10_000 ether);
        clawd.mint(agent, 1_000 ether);
        clawd.mint(agent2, 1_000 ether);
    }

    // ═══════════════════════════════════════════
    //              POST JOB TESTS
    // ═══════════════════════════════════════════

    function test_postJob() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        uint256 jobId = board.postJob("Test job", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();
        
        assertEq(jobId, 0);
        assertEq(board.getJobCount(), 1);
        assertEq(clawd.balanceOf(address(board)), 200 ether); // maxPrice escrowed
    }

    function test_postJob_revertNoDescription() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        vm.expectRevert("Description required");
        board.postJob("", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();
    }

    function test_postJob_revertMinGtMax() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        vm.expectRevert("Max must be >= min");
        board.postJob("Test", 200 ether, 100 ether, 60, 300);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════
    //          DUTCH AUCTION PRICING
    // ═══════════════════════════════════════════

    function test_getCurrentPrice_atStart() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();
        
        // At start, price should be minPrice
        assertEq(board.getCurrentPrice(0), 100 ether);
    }

    function test_getCurrentPrice_atMidpoint() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();
        
        // At 30s (half duration), price should be 150 (midpoint)
        vm.warp(block.timestamp + 30);
        assertEq(board.getCurrentPrice(0), 150 ether);
    }

    function test_getCurrentPrice_atEnd() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();
        
        // After auction ends, price should be maxPrice
        vm.warp(block.timestamp + 61);
        assertEq(board.getCurrentPrice(0), 200 ether);
    }

    // ═══════════════════════════════════════════
    //              CLAIM JOB TESTS
    // ═══════════════════════════════════════════

    function test_claimJob() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        // Advance 30s, price should be 150
        vm.warp(block.timestamp + 30);
        
        vm.prank(agent);
        board.claimJob(0, 21548);
        
        // Agent gets job, poster gets refund of (200 - 150) = 50
        (, , , , , uint8 status) = board.getJobAgent(0);
        assertEq(status, 0); // agent rating starts at 0
        
        // Check board holds 150, poster got 50 back
        assertEq(clawd.balanceOf(address(board)), 150 ether);
    }

    function test_claimJob_revertPosterCantClaim() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.expectRevert("Poster cannot claim own job");
        board.claimJob(0, 21548);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════
    //          FULL LIFECYCLE TEST
    // ═══════════════════════════════════════════

    function test_fullLifecycle() public {
        // Poster posts job
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Generate avatar", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        uint256 posterBalBefore = clawd.balanceOf(poster);

        // Agent claims at midpoint (150 CLAWD)
        vm.warp(block.timestamp + 30);
        vm.prank(agent);
        board.claimJob(0, 21548);

        // Poster should have gotten 50 CLAWD refund
        assertEq(clawd.balanceOf(poster), posterBalBefore + 50 ether);

        // Agent submits work
        vm.prank(agent);
        board.submitWork(0, "ipfs://bafkreiexample");

        // Poster approves with rating 90
        uint256 agentBalBefore = clawd.balanceOf(agent);
        vm.prank(poster);
        board.approveWork(0, 90);

        // Agent should have received 150 CLAWD
        assertEq(clawd.balanceOf(agent), agentBalBefore + 150 ether);

        // Check agent stats
        (uint256 completed, uint256 disputed, uint256 earned, uint256 avgRating) = board.getAgentStats(agent);
        assertEq(completed, 1);
        assertEq(disputed, 0);
        assertEq(earned, 150 ether);
        assertEq(avgRating, 90);
    }

    // ═══════════════════════════════════════════
    //           DISPUTE + EXPIRE TESTS
    // ═══════════════════════════════════════════

    function test_disputeWork() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.prank(agent);
        board.claimJob(0, 21548);

        vm.prank(agent);
        board.submitWork(0, "ipfs://bad-work");

        uint256 posterBalBefore = clawd.balanceOf(poster);
        vm.prank(poster);
        board.disputeWork(0);

        // Poster gets the claim price back
        assertGt(clawd.balanceOf(poster), posterBalBefore);
        
        // Check agent dispute recorded
        (, uint256 disputed, ,) = board.getAgentStats(agent);
        assertEq(disputed, 1);
    }

    function test_expireJob() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.prank(agent);
        board.claimJob(0, 21548);

        // Fast forward past work deadline
        vm.warp(block.timestamp + 301);

        uint256 posterBalBefore = clawd.balanceOf(poster);
        board.expireJob(0); // Anyone can call

        // Poster gets refund
        assertGt(clawd.balanceOf(poster), posterBalBefore);
    }

    function test_cancelJob() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        
        uint256 balBefore = clawd.balanceOf(poster);
        board.cancelJob(0);
        vm.stopPrank();

        // Full refund (maxPrice)
        assertEq(clawd.balanceOf(poster), balBefore + 200 ether);
    }

    // ═══════════════════════════════════════════
    //           EDGE CASES
    // ═══════════════════════════════════════════

    function test_claimJob_atMinPrice() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        // Claim immediately (at minPrice)
        vm.prank(agent);
        board.claimJob(0, 21548);

        // Price should be minPrice (100), refund should be 100
        assertEq(clawd.balanceOf(address(board)), 100 ether);
    }

    function test_submitWork_revertAfterDeadline() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.prank(agent);
        board.claimJob(0, 21548);

        // Fast forward past deadline
        vm.warp(block.timestamp + 301);

        vm.prank(agent);
        vm.expectRevert("Work deadline passed");
        board.submitWork(0, "ipfs://late");
    }

    function test_reclaimWork() public {
        // Post and claim
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        uint256 claimTime = block.timestamp;
        vm.prank(agent);
        board.claimJob(0, 21548);

        vm.prank(agent);
        board.submitWork(0, "ipfs://work");

        // Try reclaim too early (only 500s from claim, need 900 = 3 * 300)
        vm.warp(claimTime + 500);
        vm.prank(agent);
        vm.expectRevert("Review period not over");
        board.reclaimWork(0);

        // Advance past 3x work deadline from claim time
        vm.warp(claimTime + 901);
        uint256 agentBalBefore = clawd.balanceOf(agent);
        vm.prank(agent);
        board.reclaimWork(0);

        // Agent gets paid
        assertGt(clawd.balanceOf(agent), agentBalBefore);
        
        // Counts as completed
        (uint256 completed, , ,) = board.getAgentStats(agent);
        assertEq(completed, 1);
    }

    function test_multipleJobs() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 1000 ether);
        board.postJob("Job 1", 100 ether, 200 ether, 60, 300);
        board.postJob("Job 2", 50 ether, 100 ether, 30, 600);
        board.postJob("Job 3", 200 ether, 500 ether, 120, 3600);
        vm.stopPrank();

        assertEq(board.getJobCount(), 3);
    }
}
