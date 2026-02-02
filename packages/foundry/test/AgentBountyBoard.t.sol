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

// Mock ERC-8004 Agent Registry for testing
contract MockAgentRegistry {
    struct Agent {
        address owner;
        bytes32 metadataURI;
        bool active;
    }
    
    mapping(uint256 => Agent) public agents;
    
    function registerAgent(uint256 agentId, address owner, bytes32 metadataURI) external {
        agents[agentId] = Agent(owner, metadataURI, true);
    }
    
    function deactivateAgent(uint256 agentId) external {
        agents[agentId].active = false;
    }
}

contract AgentBountyBoardTest is Test {
    AgentBountyBoard public board;
    MockCLAWD public clawd;
    MockAgentRegistry public registry;
    
    address owner = address(0x99);
    address poster = address(0x1);
    address agent = address(0x2);
    address agent2 = address(0x3);
    address feeRecipient = address(0x4);
    
    uint256 constant AGENT_ID = 21548;
    
    function setUp() public {
        vm.startPrank(owner);
        clawd = new MockCLAWD();
        registry = new MockAgentRegistry();
        board = new AgentBountyBoard(address(clawd), address(registry));
        board.setFeeRecipient(feeRecipient);
        vm.stopPrank();
        
        // Fund accounts
        clawd.mint(poster, 10_000 ether);
        clawd.mint(agent, 1_000 ether);
        clawd.mint(agent2, 1_000 ether);
        
        // Register agent in mock registry
        registry.registerAgent(AGENT_ID, agent, bytes32("ipfs://QmTest"));
    }

    // ═══════════════════════════════════════════
    //              CONSTRUCTOR TESTS
    // ═══════════════════════════════════════════

    function test_Constructor() public {
        assertEq(address(board.clawd()), address(clawd));
        assertEq(board.agentRegistry(), address(registry));
        assertEq(board.feeRecipient(), feeRecipient);
        assertEq(board.protocolFeeBps(), 0);
        assertEq(board.owner(), owner);
    }
    
    function test_Constructor_ZeroAddressReverts() public {
        vm.expectRevert(AgentBountyBoard.InvalidAddress.selector);
        new AgentBountyBoard(address(0), address(registry));
    }

    // ═══════════════════════════════════════════
    //              ADMIN FUNCTIONS
    // ═══════════════════════════════════════════

    function test_SetAgentRegistry() public {
        address newRegistry = address(0x123);
        
        vm.prank(owner);
        board.setAgentRegistry(newRegistry);
        
        assertEq(board.agentRegistry(), newRegistry);
    }
    
    function test_SetProtocolFee() public {
        uint256 newFee = 300; // 3%
        
        vm.prank(owner);
        board.setProtocolFee(newFee);
        
        assertEq(board.protocolFeeBps(), newFee);
    }
    
    function test_SetProtocolFee_TooHighReverts() public {
        vm.prank(owner);
        vm.expectRevert(AgentBountyBoard.FeeTooHigh.selector);
        board.setProtocolFee(600); // 6% > 5% max
    }
    
    function test_SetFeeRecipient() public {
        address newRecipient = address(0x555);
        
        vm.prank(owner);
        board.setFeeRecipient(newRecipient);
        
        assertEq(board.feeRecipient(), newRecipient);
    }
    
    function test_VerifyAgentOwner() public {
        address multiSig = address(0xABC);
        
        vm.prank(owner);
        board.verifyAgentOwner(multiSig);
        
        assertTrue(board.verifiedAgentOwners(multiSig));
    }
    
    function test_Pause() public {
        vm.prank(owner);
        board.pause();
        
        assertTrue(board.paused());
    }
    
    function test_Unpause() public {
        vm.startPrank(owner);
        board.pause();
        board.unpause();
        vm.stopPrank();
        
        assertFalse(board.paused());
    }
    
    function test_AdminFunctions_OnlyOwner() public {
        vm.prank(agent);
        vm.expectRevert();
        board.setProtocolFee(100);
        
        vm.prank(agent);
        vm.expectRevert();
        board.pause();
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
        assertEq(clawd.balanceOf(address(board)), 200 ether);
        
        // Check platform stats
        (uint256 posted,,,,) = board.getPlatformStats();
        assertEq(posted, 1);
    }

    function test_postJob_revertNoDescription() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        vm.expectRevert(AgentBountyBoard.EmptyDescription.selector);
        board.postJob("", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();
    }

    function test_postJob_revertMinGtMax() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        vm.expectRevert(AgentBountyBoard.InvalidPrice.selector);
        board.postJob("Test", 200 ether, 100 ether, 60, 300);
        vm.stopPrank();
    }
    
    function test_postJob_revertWhenPaused() public {
        vm.prank(owner);
        board.pause();
        
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
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
        
        assertEq(board.getCurrentPrice(0), 100 ether);
    }

    function test_getCurrentPrice_atMidpoint() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();
        
        vm.warp(block.timestamp + 30);
        assertEq(board.getCurrentPrice(0), 150 ether);
    }

    function test_getCurrentPrice_atEnd() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();
        
        vm.warp(block.timestamp + 61);
        assertEq(board.getCurrentPrice(0), 200 ether);
    }

    // ═══════════════════════════════════════════
    //              CLAIM JOB TESTS (ERC-8004)
    // ═══════════════════════════════════════════

    function test_claimJob_WithERC8004Verification() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.warp(block.timestamp + 30);
        
        // Agent claims with their verified ERC-8004 ID
        vm.prank(agent);
        board.claimJob(0, AGENT_ID);
        
        assertEq(clawd.balanceOf(address(board)), 150 ether);
    }
    
    function test_claimJob_VerifiedOwnerCanClaim() public {
        // Register agent under a multi-sig
        address multiSig = address(0xABC);
        registry.registerAgent(999, multiSig, bytes32("ipfs://test"));
        clawd.mint(multiSig, 1000 ether);
        
        // Verify the owner
        vm.prank(owner);
        board.verifyAgentOwner(multiSig);
        
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.warp(block.timestamp + 30);
        
        // Multi-sig claims with their agent ID
        vm.prank(multiSig);
        board.claimJob(0, 999);
        
        assertEq(clawd.balanceOf(address(board)), 150 ether);
    }
    
    function test_claimJob_UnregisteredAgentReverts() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.warp(block.timestamp + 30);
        
        // Try to claim with unregistered agent ID
        vm.prank(agent2);
        vm.expectRevert(AgentBountyBoard.AgentNotRegistered.selector);
        board.claimJob(0, 99999);
    }
    
    function test_claimJob_NoRegistry() public {
        // Create board without registry
        vm.startPrank(owner);
        AgentBountyBoard boardNoRegistry = new AgentBountyBoard(address(clawd), address(0));
        vm.stopPrank();
        
        vm.startPrank(poster);
        clawd.approve(address(boardNoRegistry), 200 ether);
        boardNoRegistry.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.warp(block.timestamp + 30);
        
        // Anyone can claim when no registry set
        vm.prank(agent2);
        boardNoRegistry.claimJob(0, 99999); // Any ID works
        
        assertEq(clawd.balanceOf(address(boardNoRegistry)), 150 ether);
    }

    function test_claimJob_revertPosterCantClaim() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.expectRevert(AgentBountyBoard.PosterCannotClaimOwnJob.selector);
        board.claimJob(0, AGENT_ID);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════
    //          FULL LIFECYCLE TEST
    // ═══════════════════════════════════════════

    function test_fullLifecycle() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Generate avatar", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        uint256 posterBalBefore = clawd.balanceOf(poster);

        vm.warp(block.timestamp + 30);
        vm.prank(agent);
        board.claimJob(0, AGENT_ID);

        assertEq(clawd.balanceOf(poster), posterBalBefore + 50 ether);

        vm.prank(agent);
        board.submitWork(0, "ipfs://bafkreiexample");

        uint256 agentBalBefore = clawd.balanceOf(agent);
        vm.prank(poster);
        board.approveWork(0, 90);

        assertEq(clawd.balanceOf(agent), agentBalBefore + 150 ether);

        (uint256 completed, uint256 disputed, uint256 earned, uint256 avgRating, uint256 seniority) = board.getAgentStats(agent);
        assertEq(completed, 1);
        assertEq(disputed, 0);
        assertEq(earned, 150 ether);
        assertEq(avgRating, 90);
        assertEq(seniority, 0);
        
        // Check platform stats
        (,uint256 completedJobs, uint256 totalPaid,,) = board.getPlatformStats();
        assertEq(completedJobs, 1);
        assertEq(totalPaid, 150 ether);
    }
    
    function test_fullLifecycle_WithProtocolFee() public {
        // Set 2% fee
        vm.prank(owner);
        board.setProtocolFee(200);
        
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Generate avatar", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.warp(block.timestamp + 30);
        vm.prank(agent);
        board.claimJob(0, AGENT_ID);

        uint256 feeRecipientBalBefore = clawd.balanceOf(feeRecipient);
        uint256 agentBalBefore = clawd.balanceOf(agent);
        
        vm.prank(agent);
        board.submitWork(0, "ipfs://bafkreiexample");

        vm.prank(poster);
        board.approveWork(0, 90);

        // Agent gets 150 - 3 (2% fee) = 147
        assertEq(clawd.balanceOf(agent), agentBalBefore + 147 ether);
        // Fee recipient gets 3
        assertEq(clawd.balanceOf(feeRecipient), feeRecipientBalBefore + 3 ether);
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
        board.claimJob(0, AGENT_ID);

        vm.prank(agent);
        board.submitWork(0, "ipfs://bad-work");

        uint256 posterBalBefore = clawd.balanceOf(poster);
        vm.prank(poster);
        board.disputeWork(0);

        assertGt(clawd.balanceOf(poster), posterBalBefore);
        
        (,uint256 disputed,,,) = board.getPlatformStats();
        assertEq(disputed, 1);
    }

    function test_expireJob() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.prank(agent);
        board.claimJob(0, AGENT_ID);

        vm.warp(block.timestamp + 301);

        uint256 posterBalBefore = clawd.balanceOf(poster);
        board.expireJob(0);

        assertGt(clawd.balanceOf(poster), posterBalBefore);
    }

    function test_cancelJob() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        
        uint256 balBefore = clawd.balanceOf(poster);
        board.cancelJob(0);
        vm.stopPrank();

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

        vm.prank(agent);
        board.claimJob(0, AGENT_ID);

        assertEq(clawd.balanceOf(address(board)), 100 ether);
    }

    function test_submitWork_revertAfterDeadline() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.prank(agent);
        board.claimJob(0, AGENT_ID);

        vm.warp(block.timestamp + 301);

        vm.prank(agent);
        vm.expectRevert(AgentBountyBoard.WorkDeadlinePassed.selector);
        board.submitWork(0, "ipfs://late");
    }

    function test_reclaimWork() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        uint256 claimTime = block.timestamp;
        vm.prank(agent);
        board.claimJob(0, AGENT_ID);

        vm.prank(agent);
        board.submitWork(0, "ipfs://work");

        vm.warp(claimTime + 500);
        vm.prank(agent);
        vm.expectRevert(AgentBountyBoard.ReviewPeriodNotOver.selector);
        board.reclaimWork(0);

        vm.warp(claimTime + 901);
        uint256 agentBalBefore = clawd.balanceOf(agent);
        vm.prank(agent);
        board.reclaimWork(0);

        assertGt(clawd.balanceOf(agent), agentBalBefore);
        
        (uint256 completed,,,,) = board.getAgentStats(agent);
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
        
        (uint256 posted,,,,) = board.getPlatformStats();
        assertEq(posted, 3);
    }
    
    function test_AgentSeniority() public {
        vm.startPrank(poster);
        clawd.approve(address(board), 400 ether);
        board.postJob("Job 1", 100 ether, 200 ether, 60, 300);
        board.postJob("Job 2", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        uint256 firstJobTime = block.timestamp;
        
        // First job
        vm.prank(agent);
        board.claimJob(0, AGENT_ID);
        vm.prank(agent);
        board.submitWork(0, "ipfs://work1");
        vm.prank(poster);
        board.approveWork(0, 80);
        
        // Warp forward 5 days
        vm.warp(block.timestamp + 5 days);
        
        // Second job
        vm.prank(agent);
        board.claimJob(1, AGENT_ID);
        vm.prank(agent);
        board.submitWork(1, "ipfs://work2");
        vm.prank(poster);
        board.approveWork(1, 90);
        
        (,,,, uint256 seniority) = board.getAgentStats(agent);
        assertEq(seniority, 5); // 5 days
    }
    
    function test_RecoverStuckTokens() public {
        // Create another token and send to board
        MockCLAWD otherToken = new MockCLAWD();
        otherToken.mint(address(board), 1000 ether);
        
        uint256 ownerBalBefore = otherToken.balanceOf(owner);
        
        vm.prank(owner);
        board.recoverStuckTokens(address(otherToken));
        
        assertEq(otherToken.balanceOf(owner), ownerBalBefore + 1000 ether);
    }
    
    function test_RecoverStuckTokens_ClawdReverts() public {
        vm.prank(owner);
        vm.expectRevert(AgentBountyBoard.InvalidAddress.selector);
        board.recoverStuckTokens(address(clawd));
    }
    
    function test_WithdrawFees() public {
        // Set 2% fee and complete a job
        vm.prank(owner);
        board.setProtocolFee(200);
        
        vm.startPrank(poster);
        clawd.approve(address(board), 200 ether);
        board.postJob("Test", 100 ether, 200 ether, 60, 300);
        vm.stopPrank();

        vm.warp(block.timestamp + 30);
        vm.prank(agent);
        board.claimJob(0, AGENT_ID);
        
        vm.prank(agent);
        board.submitWork(0, "ipfs://work");
        
        vm.prank(poster);
        board.approveWork(0, 90);
        
        // 150 * 2% = 3 ether in fees
        uint256 feeRecipientBalBefore = clawd.balanceOf(feeRecipient);
        
        vm.prank(owner);
        board.withdrawFees();
        
        assertEq(clawd.balanceOf(feeRecipient), feeRecipientBalBefore + 3 ether);
    }
}
