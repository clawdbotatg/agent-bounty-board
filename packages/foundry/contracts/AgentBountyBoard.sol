// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title AgentBountyBoard
 * @notice Dutch auction job market for ERC-8004 registered AI agents
 * @dev Jobs start at minPrice and linearly increase to maxPrice over auctionDuration.
 *      First agent to claim gets the job at the current price.
 *      Agent submits work, poster approves or disputes.
 *      CLAWD token is used for all payments (escrow model).
 */
contract AgentBountyBoard is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable clawd;

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
    }

    Job[] public jobs;
    mapping(address => AgentStats) public agentStats;

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
        uint256 paidAmount
    );
    event WorkSubmitted(uint256 indexed jobId, string submissionURI);
    event WorkApproved(uint256 indexed jobId, uint8 rating, uint256 paidAmount);
    event WorkDisputed(uint256 indexed jobId);
    event JobCancelled(uint256 indexed jobId);
    event JobExpired(uint256 indexed jobId);

    constructor(address _clawd) {
        require(_clawd != address(0), "Invalid CLAWD address");
        clawd = IERC20(_clawd);
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
    ) external nonReentrant returns (uint256 jobId) {
        require(maxPrice > 0, "Max price must be > 0");
        require(maxPrice >= minPrice, "Max must be >= min");
        require(auctionDuration > 0, "Auction duration must be > 0");
        require(workDeadline > 0, "Work deadline must be > 0");
        require(bytes(description).length > 0, "Description required");

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

        emit JobPosted(jobId, msg.sender, description, minPrice, maxPrice, auctionDuration, workDeadline);
    }

    /**
     * @notice Approve submitted work and pay the agent
     * @param jobId The job to approve
     * @param rating Quality rating 0-100
     */
    function approveWork(uint256 jobId, uint8 rating) external nonReentrant {
        Job storage job = jobs[jobId];
        require(msg.sender == job.poster, "Only poster can approve");
        require(job.status == JobStatus.Submitted, "Job not submitted");
        require(rating <= 100, "Rating must be 0-100");

        job.status = JobStatus.Completed;
        job.rating = rating;

        // Update agent stats
        AgentStats storage stats = agentStats[job.agent];
        stats.completedJobs++;
        stats.totalEarned += job.paidAmount;
        stats.totalRating += rating;

        // Pay the agent
        clawd.safeTransfer(job.agent, job.paidAmount);

        emit WorkApproved(jobId, rating, job.paidAmount);
    }

    /**
     * @notice Dispute submitted work — refund escrow to poster
     * @param jobId The job to dispute
     */
    function disputeWork(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        require(msg.sender == job.poster, "Only poster can dispute");
        require(job.status == JobStatus.Submitted, "Job not submitted");

        job.status = JobStatus.Disputed;

        // Update agent stats
        agentStats[job.agent].disputedJobs++;

        // Refund the escrowed amount to poster
        clawd.safeTransfer(job.poster, job.paidAmount);

        emit WorkDisputed(jobId);
    }

    /**
     * @notice Cancel an open job (only if unclaimed)
     * @param jobId The job to cancel
     */
    function cancelJob(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        require(msg.sender == job.poster, "Only poster can cancel");
        require(job.status == JobStatus.Open, "Job not open");

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
     * @param agentId The agent's ERC-8004 ID (verified client-side)
     */
    function claimJob(uint256 jobId, uint256 agentId) external nonReentrant {
        Job storage job = jobs[jobId];
        require(job.status == JobStatus.Open, "Job not open");
        require(msg.sender != job.poster, "Poster cannot claim own job");

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

        emit JobClaimed(jobId, msg.sender, agentId, currentPrice);
    }

    /**
     * @notice Reclaim funds if poster never responds to submission
     * @dev Agent can reclaim after 2x the work deadline passes from submission
     * @param jobId The job to reclaim
     */
    function reclaimWork(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        require(msg.sender == job.agent, "Only assigned agent");
        require(job.status == JobStatus.Submitted, "Job not submitted");
        // Allow reclaim after 2x the work deadline from when it was claimed
        // This gives poster ample time to review
        uint256 reviewDeadline = job.claimedAt + (job.workDeadline * 3);
        require(block.timestamp > reviewDeadline, "Review period not over");

        job.status = JobStatus.Completed;
        job.rating = 0; // No rating for auto-reclaim

        // Update agent stats (counts as completed but no rating boost)
        AgentStats storage stats = agentStats[job.agent];
        stats.completedJobs++;
        stats.totalEarned += job.paidAmount;

        // Pay the agent
        clawd.safeTransfer(job.agent, job.paidAmount);

        emit WorkApproved(jobId, 0, job.paidAmount);
    }

    /**
     * @notice Submit completed work
     * @param jobId The job to submit work for
     * @param submissionURI URI pointing to the work (IPFS, https, etc.)
     */
    function submitWork(uint256 jobId, string calldata submissionURI) external nonReentrant {
        Job storage job = jobs[jobId];
        require(msg.sender == job.agent, "Only assigned agent");
        require(job.status == JobStatus.Claimed, "Job not claimed");
        require(bytes(submissionURI).length > 0, "Submission URI required");
        require(
            block.timestamp <= job.claimedAt + job.workDeadline,
            "Work deadline passed"
        );

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
    function expireJob(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        require(job.status == JobStatus.Claimed, "Job not in claimed state");
        require(
            block.timestamp > job.claimedAt + job.workDeadline,
            "Deadline not yet passed"
        );

        job.status = JobStatus.Expired;

        // Refund escrowed amount to poster (agent failed to deliver)
        clawd.safeTransfer(job.poster, job.paidAmount);

        emit JobExpired(jobId);
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
        require(jobId < jobs.length, "Job does not exist");
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
        uint256 avgRating
    ) {
        AgentStats storage stats = agentStats[agent];
        uint256 avg = stats.completedJobs > 0
            ? stats.totalRating / stats.completedJobs
            : 0;
        return (stats.completedJobs, stats.disputedJobs, stats.totalEarned, avg);
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
