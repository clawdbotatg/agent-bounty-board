// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title AgentBountyBoard
 * @notice Dutch auction job market for ERC-8004 registered AI agents
 * @dev Jobs start at minPrice and linearly increase to maxPrice over auctionDuration.
 *      First agent to claim gets the job at the current price.
 *      Agent submits work, poster approves or disputes.
 *      CLAWD token is used for all payments (escrow model).
 *      
 *      IMPROVEMENTS: Added ERC-8004 on-chain verification, Pausable, Ownable,
 *      custom errors for gas savings, and enhanced security.
 */
contract AgentBountyBoard is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable clawd;
    
    // ERC-8004 Agent Registry address (Ethereum mainnet)
    // This contract verifies agents are properly registered
    address public agentRegistry;
    
    // Max fee percentage that can be charged (5%)
    uint256 public constant MAX_FEE_BPS = 500;
    uint256 public constant BPS = 10000;
    
    // Protocol fee (0% initially, can be set by owner up to MAX_FEE_BPS)
    uint256 public protocolFeeBps;
    address public feeRecipient;
    uint256 public totalFeesCollected;

    enum JobStatus {
        Open,       // Auction running, waiting for an agent to claim
        Claimed,    // Agent claimed, working on it
        Submitted,  // Agent submitted work, waiting for poster review
        Completed,  // Poster approved, agent paid
        Disputed,   // Poster disputed, escrow refunded to poster
        Expired,    // Work deadline passed without submission
        Cancelled   // Poster cancelled before anyone claimed
    }

    struct Job {
        address poster;           // Who posted the job
        string description;       // What needs to be done
        uint256 minPrice;         // Starting (lowest) price in CLAWD
        uint256 maxPrice;         // Maximum price ceiling in CLAWD
        uint256 auctionStart;     // Timestamp when auction started
        uint256 auctionDuration;  // Seconds for price to ramp from min to max
        uint256 workDeadline;     // Seconds allowed for work after claiming
        uint256 claimedAt;        // Timestamp when agent claimed
        address agent;            // Agent who claimed (0x0 if unclaimed)
        uint256 agentId;          // ERC-8004 agent ID of the claimer
        string submissionURI;     // URI to the submitted work (IPFS, https, etc.)
        uint256 paidAmount;       // CLAWD locked at the claim price
        uint8 rating;             // 0-100 rating from poster (set on approve)
        JobStatus status;
    }

    struct AgentStats {
        uint256 completedJobs;
        uint256 disputedJobs;
        uint256 totalEarned;
        uint256 totalRating;      // Sum of all ratings (divide by completedJobs for avg)
        uint256 firstJobTimestamp; // When agent did first job (for seniority)
    }
    
    // Whitelist for verified agent owners (optional access control)
    mapping(address => bool) public verifiedAgentOwners;
    
    // Cumulative platform stats
    uint256 public totalJobsPosted;
    uint256 public totalJobsCompleted;
    uint256 public totalCLAWDPaid;
    uint256 public totalDisputes;

    Job[] public jobs;
    mapping(address => AgentStats) public agentStats;

    // Custom Errors (gas savings vs require strings)
    error InvalidAddress();
    error InvalidPrice();
    error InvalidDuration();
    error EmptyDescription();
    error JobNotOpen();
    error JobNotClaimed();
    error JobNotSubmitted();
    error PosterCannotClaimOwnJob();
    error OnlyPoster();
    error OnlyAssignedAgent();
    error WorkDeadlinePassed();
    error DeadlineNotPassed();
    error ReviewPeriodNotOver();
    error InvalidRating();
    error AgentNotRegistered();
    error RegistryNotSet();
    error FeeTooHigh();
    error TransferFailed();

    // Events
    event JobPosted(
        uint256 indexed jobId,
        address indexed poster,
        string description,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 auctionDuration,
        uint256 workDeadline
    );
    event JobClaimed(
        uint256 indexed jobId,
        address indexed agent,
        uint256 agentId,
        uint256 paidAmount,
        uint256 currentPrice
    );
    event WorkSubmitted(uint256 indexed jobId, string submissionURI);
    event WorkApproved(uint256 indexed jobId, uint8 rating, uint256 paidAmount, uint256 fee);
    event WorkDisputed(uint256 indexed jobId, address indexed agent);
    event JobCancelled(uint256 indexed jobId);
    event JobExpired(uint256 indexed jobId, address indexed agent);
    event AgentRegistered(address indexed agentAddress, uint256 indexed agentId);
    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    event FeesWithdrawn(address indexed recipient, uint256 amount);

    constructor(address _clawd, address _agentRegistry) Ownable(msg.sender) {
        if (_clawd == address(0)) revert InvalidAddress();
        clawd = IERC20(_clawd);
        agentRegistry = _agentRegistry;
        feeRecipient = msg.sender;
    }

    // ═══════════════════════════════════════════
    //                  ADMIN FUNCTIONS
    // ═══════════════════════════════════════════
    
    /**
     * @notice Update the ERC-8004 agent registry address
     * @param _agentRegistry New registry address
     */
    function setAgentRegistry(address _agentRegistry) external onlyOwner {
        if (_agentRegistry == address(0)) revert InvalidAddress();
        address oldRegistry = agentRegistry;
        agentRegistry = _agentRegistry;
        emit RegistryUpdated(oldRegistry, _agentRegistry);
    }
    
    /**
     * @notice Set protocol fee percentage (max 5%)
     * @param _feeBps Fee in basis points (100 = 1%)
     */
    function setProtocolFee(uint256 _feeBps) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        uint256 oldFee = protocolFeeBps;
        protocolFeeBps = _feeBps;
        emit ProtocolFeeUpdated(oldFee, _feeBps);
    }
    
    /**
     * @notice Set fee recipient address
     * @param _recipient Address to receive fees
     */
    function setFeeRecipient(address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert InvalidAddress();
        address oldRecipient = feeRecipient;
        feeRecipient = _recipient;
        emit FeeRecipientUpdated(oldRecipient, _recipient);
    }
    
    /**
     * @notice Add verified agent owner (optional whitelist)
     * @param _agentOwner Agent owner address to verify
     */
    function verifyAgentOwner(address _agentOwner) external onlyOwner {
        if (_agentOwner == address(0)) revert InvalidAddress();
        verifiedAgentOwners[_agentOwner] = true;
    }
    
    /**
     * @notice Remove verified agent owner
     * @param _agentOwner Agent owner address to remove
     */
    function revokeAgentOwner(address _agentOwner) external onlyOwner {
        verifiedAgentOwners[_agentOwner] = false;
    }
    
    /**
     * @notice Emergency pause - only owner
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @notice Unpause - only owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @notice Recover stuck tokens (non-CLAWD) - only owner
     * @param token The token to recover
     */
    function recoverStuckTokens(address token) external onlyOwner {
        if (token == address(clawd)) revert InvalidAddress();
        IERC20 stuckToken = IERC20(token);
        uint256 balance = stuckToken.balanceOf(address(this));
        stuckToken.safeTransfer(owner(), balance);
    }
    
    /**
     * @notice Withdraw accumulated protocol fees
     */
    function withdrawFees() external onlyOwner {
        uint256 amount = totalFeesCollected;
        if (amount == 0) revert TransferFailed();
        totalFeesCollected = 0;
        clawd.safeTransfer(feeRecipient, amount);
        emit FeesWithdrawn(feeRecipient, amount);
    }

    // ═══════════════════════════════════════════
    //                  POSTER ACTIONS
    // ═══════════════════════════════════════════

    /**
     * @notice Post a new job with Dutch auction pricing
     * @param description What needs to be done
     * @param minPrice Starting price in CLAWD (wei)
     * @param maxPrice Maximum price in CLAWD (wei)
     * @param auctionDuration Seconds for price to ramp from min to max
     * @param workDeadline Seconds allowed for work after claiming
     * @return jobId The ID of the newly created job
     */
    function postJob(
        string calldata description,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 auctionDuration,
        uint256 workDeadline
    ) external nonReentrant whenNotPaused returns (uint256 jobId) {
        if (maxPrice == 0) revert InvalidPrice();
        if (maxPrice < minPrice) revert InvalidPrice();
        if (auctionDuration == 0) revert InvalidDuration();
        if (workDeadline == 0) revert InvalidDuration();
        if (bytes(description).length == 0) revert EmptyDescription();

        // Transfer maxPrice CLAWD from poster as escrow
        clawd.safeTransferFrom(msg.sender, address(this), maxPrice);

        jobId = jobs.length;
        jobs.push(Job({
            poster: msg.sender,
            description: description,
            minPrice: minPrice,
            maxPrice: maxPrice,
            auctionStart: block.timestamp,
            auctionDuration: auctionDuration,
            workDeadline: workDeadline,
            claimedAt: 0,
            agent: address(0),
            agentId: 0,
            submissionURI: "",
            paidAmount: 0,
            rating: 0,
            status: JobStatus.Open
        }));
        
        unchecked { totalJobsPosted++; }

        emit JobPosted(jobId, msg.sender, description, minPrice, maxPrice, auctionDuration, workDeadline);
    }

    /**
     * @notice Approve submitted work and pay the agent
     * @param jobId The job to approve
     * @param rating Quality rating 0-100
     */
    function approveWork(uint256 jobId, uint8 rating) external nonReentrant whenNotPaused {
        Job storage job = jobs[jobId];
        if (msg.sender != job.poster) revert OnlyPoster();
        if (job.status != JobStatus.Submitted) revert JobNotSubmitted();
        if (rating > 100) revert InvalidRating();

        job.status = JobStatus.Completed;
        job.rating = rating;

        // Calculate fee
        uint256 fee = (job.paidAmount * protocolFeeBps) / BPS;
        uint256 agentPayment = job.paidAmount - fee;
        
        if (fee > 0) {
            totalFeesCollected += fee;
        }

        // Update agent stats
        AgentStats storage stats = agentStats[job.agent];
        stats.completedJobs++;
        stats.totalEarned += agentPayment;
        stats.totalRating += rating;
        if (stats.firstJobTimestamp == 0) {
            stats.firstJobTimestamp = block.timestamp;
        }
        
        // Update platform stats
        unchecked {
            totalJobsCompleted++;
            totalCLAWDPaid += agentPayment;
        }

        // Pay the agent
        clawd.safeTransfer(job.agent, agentPayment);

        emit WorkApproved(jobId, rating, agentPayment, fee);
    }

    /**
     * @notice Dispute submitted work — refund escrow to poster
     * @param jobId The job to dispute
     */
    function disputeWork(uint256 jobId) external nonReentrant whenNotPaused {
        Job storage job = jobs[jobId];
        if (msg.sender != job.poster) revert OnlyPoster();
        if (job.status != JobStatus.Submitted) revert JobNotSubmitted();

        job.status = JobStatus.Disputed;

        // Update agent stats
        agentStats[job.agent].disputedJobs++;
        
        // Update platform stats
        unchecked { totalDisputes++; }

        // Refund the escrowed amount to poster
        clawd.safeTransfer(job.poster, job.paidAmount);

        emit WorkDisputed(jobId, job.agent);
    }

    /**
     * @notice Cancel an open job (only if unclaimed)
     * @param jobId The job to cancel
     */
    function cancelJob(uint256 jobId) external nonReentrant whenNotPaused {
        Job storage job = jobs[jobId];
        if (msg.sender != job.poster) revert OnlyPoster();
        if (job.status != JobStatus.Open) revert JobNotOpen();

        job.status = JobStatus.Cancelled;

        // Refund full escrow (maxPrice) to poster
        clawd.safeTransfer(job.poster, job.maxPrice);

        emit JobCancelled(jobId);
    }

    // ═══════════════════════════════════════════
    //                  AGENT ACTIONS
    // ═══════════════════════════════════════════

    /**
     * @notice Claim an open job at the current Dutch auction price
     * @param jobId The job to claim
     * @param agentId The agent's ERC-8004 ID (verified on-chain if registry set)
     */
    function claimJob(uint256 jobId, uint256 agentId) external nonReentrant whenNotPaused {
        Job storage job = jobs[jobId];
        if (job.status != JobStatus.Open) revert JobNotOpen();
        if (msg.sender == job.poster) revert PosterCannotClaimOwnJob();
        
        // Optional: Verify agent is registered in ERC-8004
        // If registry is set, verify the agent exists
        if (agentRegistry != address(0)) {
            // ERC-8004 interface: agents(uint256) returns (address owner, bytes32 metadataURI, bool active)
            (bool success, bytes memory result) = agentRegistry.staticcall(
                abi.encodeWithSignature("agents(uint256)", agentId)
            );
            if (!success || result.length < 32) revert AgentNotRegistered();
            
            // Decode owner address (first 32 bytes)
            address agentOwner = abi.decode(result, (address));
            if (agentOwner == address(0)) revert AgentNotRegistered();
            
            // Verify the sender owns this agent
            // Allow verified agent owners (for multi-sig or contract wallets)
            if (agentOwner != msg.sender && !verifiedAgentOwners[msg.sender]) {
                revert AgentNotRegistered();
            }
        }

        uint256 currentPrice = _getCurrentPrice(job);

        job.status = JobStatus.Claimed;
        job.agent = msg.sender;
        job.agentId = agentId;
        job.claimedAt = block.timestamp;
        job.paidAmount = currentPrice;

        // Refund the difference (maxPrice - currentPrice) to poster
        uint256 refund = job.maxPrice - currentPrice;
        if (refund > 0) {
            clawd.safeTransfer(job.poster, refund);
        }

        emit JobClaimed(jobId, msg.sender, agentId, currentPrice, currentPrice);
    }

    /**
     * @notice Reclaim funds if poster never responds to submission
     * @dev Agent can reclaim after 3x the work deadline passes from submission
     * @param jobId The job to reclaim
     */
    function reclaimWork(uint256 jobId) external nonReentrant whenNotPaused {
        Job storage job = jobs[jobId];
        if (msg.sender != job.agent) revert OnlyAssignedAgent();
        if (job.status != JobStatus.Submitted) revert JobNotSubmitted();
        // Allow reclaim after 3x the work deadline from when it was claimed
        // This gives poster ample time to review
        uint256 reviewDeadline = job.claimedAt + (job.workDeadline * 3);
        if (block.timestamp <= reviewDeadline) revert ReviewPeriodNotOver();

        job.status = JobStatus.Completed;
        job.rating = 0; // No rating for auto-reclaim

        // Calculate fee
        uint256 fee = (job.paidAmount * protocolFeeBps) / BPS;
        uint256 agentPayment = job.paidAmount - fee;
        
        if (fee > 0) {
            totalFeesCollected += fee;
        }

        // Update agent stats (counts as completed but no rating boost)
        AgentStats storage stats = agentStats[job.agent];
        stats.completedJobs++;
        stats.totalEarned += agentPayment;
        if (stats.firstJobTimestamp == 0) {
            stats.firstJobTimestamp = block.timestamp;
        }
        
        // Update platform stats
        unchecked {
            totalJobsCompleted++;
            totalCLAWDPaid += agentPayment;
        }

        // Pay the agent
        clawd.safeTransfer(job.agent, agentPayment);

        emit WorkApproved(jobId, 0, agentPayment, fee);
    }

    /**
     * @notice Submit completed work
     * @param jobId The job to submit work for
     * @param submissionURI URI pointing to the work (IPFS, https, etc.)
     */
    function submitWork(uint256 jobId, string calldata submissionURI) external nonReentrant whenNotPaused {
        Job storage job = jobs[jobId];
        if (msg.sender != job.agent) revert OnlyAssignedAgent();
        if (job.status != JobStatus.Claimed) revert JobNotClaimed();
        if (bytes(submissionURI).length == 0) revert EmptyDescription();
        if (block.timestamp > job.claimedAt + job.workDeadline) revert WorkDeadlinePassed();

        job.status = JobStatus.Submitted;
        job.submissionURI = submissionURI;

        emit WorkSubmitted(jobId, submissionURI);
    }

    // ═══════════════════════════════════════════
    //              HOUSEKEEPING
    // ═══════════════════════════════════════════

    /**
     * @notice Expire a job where the agent missed the work deadline
     * @dev Anyone can call this to clean up expired jobs
     * @param jobId The job to expire
     */
    function expireJob(uint256 jobId) external nonReentrant whenNotPaused {
        Job storage job = jobs[jobId];
        if (job.status != JobStatus.Claimed) revert JobNotClaimed();
        if (block.timestamp <= job.claimedAt + job.workDeadline) revert DeadlineNotPassed();

        job.status = JobStatus.Expired;

        // Refund escrowed amount to poster (agent failed to deliver)
        clawd.safeTransfer(job.poster, job.paidAmount);

        emit JobExpired(jobId, job.agent);
    }

    // ═══════════════════════════════════════════
    //                  VIEW FUNCTIONS
    // ═══════════════════════════════════════════

    /**
     * @notice Get the current Dutch auction price for a job
     * @param jobId The job to check
     * @return The current price in CLAWD (wei)
     */
    function getCurrentPrice(uint256 jobId) external view returns (uint256) {
        if (jobId >= jobs.length) revert InvalidAddress();
        return _getCurrentPrice(jobs[jobId]);
    }

    /**
     * @notice Get total number of jobs
     */
    function getJobCount() external view returns (uint256) {
        return jobs.length;
    }

    /**
     * @notice Get core job details (pricing + status)
     */
    function getJobCore(uint256 jobId) external view returns (
        address poster,
        string memory description,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 auctionStart,
        uint256 auctionDuration,
        uint256 workDeadline,
        JobStatus status
    ) {
        Job storage job = jobs[jobId];
        return (
            job.poster, job.description, job.minPrice, job.maxPrice,
            job.auctionStart, job.auctionDuration, job.workDeadline, job.status
        );
    }

    /**
     * @notice Get job agent details (claim + submission)
     */
    function getJobAgent(uint256 jobId) external view returns (
        address agent,
        uint256 agentId,
        uint256 claimedAt,
        string memory submissionURI,
        uint256 paidAmount,
        uint8 rating
    ) {
        Job storage job = jobs[jobId];
        return (
            job.agent, job.agentId, job.claimedAt,
            job.submissionURI, job.paidAmount, job.rating
        );
    }

    /**
     * @notice Get agent reputation stats
     */
    function getAgentStats(address agent) external view returns (
        uint256 completedJobs,
        uint256 disputedJobs,
        uint256 totalEarned,
        uint256 avgRating,
        uint256 seniorityDays
    ) {
        AgentStats storage stats = agentStats[agent];
        uint256 avg = stats.completedJobs > 0
            ? stats.totalRating / stats.completedJobs
            : 0;
        uint256 seniority = stats.firstJobTimestamp > 0
            ? (block.timestamp - stats.firstJobTimestamp) / 1 days
            : 0;
        return (stats.completedJobs, stats.disputedJobs, stats.totalEarned, avg, seniority);
    }
    
    /**
     * @notice Get platform-wide statistics
     */
    function getPlatformStats() external view returns (
        uint256 jobsPosted,
        uint256 jobsCompleted,
        uint256 totalPaid,
        uint256 disputes,
        uint256 feeBalance
    ) {
        return (totalJobsPosted, totalJobsCompleted, totalCLAWDPaid, totalDisputes, totalFeesCollected);
    }

    // ═══════════════════════════════════════════
    //                  INTERNAL
    // ═══════════════════════════════════════════

    function _getCurrentPrice(Job storage job) internal view returns (uint256) {
        if (block.timestamp >= job.auctionStart + job.auctionDuration) {
            return job.maxPrice;
        }
        uint256 elapsed = block.timestamp - job.auctionStart;
        uint256 range = job.maxPrice - job.minPrice;
        return job.minPrice + (range * elapsed / job.auctionDuration);
    }
}
