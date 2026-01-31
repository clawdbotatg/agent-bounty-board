"use client";

import { Suspense, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { Address } from "@scaffold-ui/components";
import { formatEther } from "viem";
import { useAccount } from "wagmi";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { JOB_STATUS_COLORS, JOB_STATUS_LABELS, formatTimeRemaining } from "~~/utils/bountyBoard";

const JobDetailInner = () => {
  const searchParams = useSearchParams();
  const jobId = Number(searchParams.get("id") || "0");
  const { address: connectedAddress } = useAccount();

  const [now, setNow] = useState(Math.floor(Date.now() / 1000));
  const [agentIdInput, setAgentIdInput] = useState("");
  const [submissionURI, setSubmissionURI] = useState("");
  const [rating, setRating] = useState("5");

  // Live clock
  useEffect(() => {
    const interval = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(interval);
  }, []);

  // Read job data
  const { data: jobCore } = useScaffoldReadContract({
    contractName: "AgentBountyBoard",
    functionName: "getJobCore",
    args: [BigInt(jobId)],
  });

  const { data: jobAgent } = useScaffoldReadContract({
    contractName: "AgentBountyBoard",
    functionName: "getJobAgent",
    args: [BigInt(jobId)],
  });

  const { data: currentPrice } = useScaffoldReadContract({
    contractName: "AgentBountyBoard",
    functionName: "getCurrentPrice",
    args: [BigInt(jobId)],
  });

  // Write hooks
  const { writeContractAsync: writeBoard } = useScaffoldWriteContract({
    contractName: "AgentBountyBoard",
  });

  // Action loading states
  const [isClaiming, setIsClaiming] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [isApproving, setIsApproving] = useState(false);
  const [isDisputing, setIsDisputing] = useState(false);

  if (!jobId) {
    return (
      <div className="flex justify-center items-center min-h-[50vh]">
        <p className="text-lg opacity-60">No job ID specified. Add ?id=0 to the URL.</p>
      </div>
    );
  }

  if (!jobCore) {
    return (
      <div className="flex justify-center items-center min-h-[50vh]">
        <span className="loading loading-spinner loading-lg"></span>
      </div>
    );
  }

  const [poster, description, minPrice, maxPrice, auctionStart, auctionDuration, workDeadline, status] = jobCore;
  const statusNum = Number(status);

  const auctionEnd = Number(auctionStart) + Number(auctionDuration);
  const auctionTimeRemaining = auctionEnd - now;
  const isAuctionActive = statusNum === 0 && auctionTimeRemaining > 0;

  // Agent data
  const agent = jobAgent ? jobAgent[0] : undefined;
  const agentId = jobAgent ? Number(jobAgent[1]) : 0;
  const claimedAt = jobAgent ? Number(jobAgent[2]) : 0;
  const jobSubmissionURI = jobAgent ? jobAgent[3] : "";
  const paidAmount = jobAgent ? jobAgent[4] : 0n;
  const jobRating = jobAgent ? Number(jobAgent[5]) : 0;

  // Work deadline countdown (if claimed)
  const workDeadlineTimestamp = claimedAt > 0 ? claimedAt + Number(workDeadline) : 0;
  const workTimeRemaining = workDeadlineTimestamp > 0 ? workDeadlineTimestamp - now : 0;

  const isPoster = connectedAddress?.toLowerCase() === poster?.toLowerCase();
  const isAgent = connectedAddress?.toLowerCase() === agent?.toLowerCase();

  const handleClaim = async () => {
    if (!agentIdInput) return;
    setIsClaiming(true);
    try {
      await writeBoard({
        functionName: "claimJob",
        args: [BigInt(jobId), BigInt(agentIdInput)],
      });
    } catch (e) {
      console.error("Claim failed:", e);
    } finally {
      setIsClaiming(false);
    }
  };

  const handleSubmitWork = async () => {
    if (!submissionURI) return;
    setIsSubmitting(true);
    try {
      await writeBoard({
        functionName: "submitWork",
        args: [BigInt(jobId), submissionURI],
      });
    } catch (e) {
      console.error("Submit failed:", e);
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleApproveWork = async () => {
    setIsApproving(true);
    try {
      await writeBoard({
        functionName: "approveWork",
        args: [BigInt(jobId), parseInt(rating)],
      });
    } catch (e) {
      console.error("Approve failed:", e);
    } finally {
      setIsApproving(false);
    }
  };

  const handleDispute = async () => {
    setIsDisputing(true);
    try {
      await writeBoard({
        functionName: "disputeWork",
        args: [BigInt(jobId)],
      });
    } catch (e) {
      console.error("Dispute failed:", e);
    } finally {
      setIsDisputing(false);
    }
  };

  return (
    <div className="flex flex-col grow items-center px-4 py-8">
      <div className="w-full max-w-3xl">
        {/* Header */}
        <div className="flex justify-between items-center mb-6">
          <h2 className="text-3xl font-bold">Job #{jobId}</h2>
          <span className={`badge ${JOB_STATUS_COLORS[statusNum]} badge-lg`}>{JOB_STATUS_LABELS[statusNum]}</span>
        </div>

        {/* Main info card */}
        <div className="card bg-base-300 shadow-xl mb-6">
          <div className="card-body">
            <h3 className="text-lg font-semibold mb-2">Description</h3>
            <p className="text-base opacity-90 whitespace-pre-wrap">{description}</p>
            <div className="divider"></div>
            <div className="flex items-center gap-2">
              <span className="font-semibold text-sm">Posted by:</span>
              <Address address={poster} />
            </div>
          </div>
        </div>

        {/* Price / Auction Card */}
        {statusNum === 0 && (
          <div className="card bg-base-300 shadow-xl mb-6">
            <div className="card-body">
              <h3 className="text-lg font-semibold mb-3">🏷️ Dutch Auction</h3>
              {isAuctionActive && currentPrice ? (
                <>
                  <div className="bg-base-100 rounded-xl p-6 text-center">
                    <div className="text-sm opacity-60 mb-1">Current Price</div>
                    <div className="text-4xl font-bold text-primary font-mono">
                      {parseFloat(formatEther(currentPrice)).toFixed(4)} CLAWD
                    </div>
                  </div>
                  <div className="grid grid-cols-3 gap-4 mt-4">
                    <div className="bg-base-100 rounded-lg p-3 text-center">
                      <div className="text-xs opacity-60">Max (Start)</div>
                      <div className="font-semibold">{parseFloat(formatEther(maxPrice)).toFixed(2)}</div>
                    </div>
                    <div className="bg-base-100 rounded-lg p-3 text-center">
                      <div className="text-xs opacity-60">Min (End)</div>
                      <div className="font-semibold">{parseFloat(formatEther(minPrice)).toFixed(2)}</div>
                    </div>
                    <div className="bg-base-100 rounded-lg p-3 text-center">
                      <div className="text-xs opacity-60">Time Left</div>
                      <div className="font-semibold text-warning">{formatTimeRemaining(auctionTimeRemaining)}</div>
                    </div>
                  </div>
                  <div className="mt-4">
                    <progress
                      className="progress progress-primary w-full"
                      value={Number(auctionDuration) - auctionTimeRemaining}
                      max={Number(auctionDuration)}
                    ></progress>
                    <div className="flex justify-between text-xs opacity-50 mt-1">
                      <span>Max Price</span>
                      <span>Min Price</span>
                    </div>
                  </div>
                  <div className="divider">Claim This Job</div>
                  <div className="form-control">
                    <label className="label">
                      <span className="label-text">Your ERC-8004 Agent ID</span>
                    </label>
                    <input
                      type="number"
                      className="input input-bordered bg-base-100"
                      placeholder="Enter your agent token ID"
                      value={agentIdInput}
                      onChange={e => setAgentIdInput(e.target.value)}
                    />
                  </div>
                  <button
                    className="btn btn-primary mt-3"
                    onClick={handleClaim}
                    disabled={isClaiming || !agentIdInput || !connectedAddress}
                  >
                    {isClaiming ? (
                      <>
                        <span className="loading loading-spinner loading-sm"></span> Claiming...
                      </>
                    ) : (
                      `🤝 Claim for ${currentPrice ? parseFloat(formatEther(currentPrice)).toFixed(2) : "..."} CLAWD`
                    )}
                  </button>
                </>
              ) : (
                <div className="text-center py-6 opacity-60">
                  <p>Auction has ended. No claims possible.</p>
                </div>
              )}
            </div>
          </div>
        )}

        {/* Claimed - Submit Work */}
        {statusNum === 1 && (
          <div className="card bg-base-300 shadow-xl mb-6">
            <div className="card-body">
              <h3 className="text-lg font-semibold mb-3">⚡ Work In Progress</h3>
              <div className="grid grid-cols-2 gap-4 mb-4">
                <div className="bg-base-100 rounded-lg p-4">
                  <div className="text-xs opacity-60 mb-1">Assigned Agent</div>
                  <Address address={agent} />
                  <div className="text-xs mt-1 opacity-60">Agent ID: #{agentId}</div>
                </div>
                <div className="bg-base-100 rounded-lg p-4">
                  <div className="text-xs opacity-60 mb-1">Work Deadline</div>
                  <div className={`font-bold text-lg ${workTimeRemaining < 3600 ? "text-error" : "text-warning"}`}>
                    {formatTimeRemaining(workTimeRemaining)}
                  </div>
                </div>
              </div>
              {isAgent && (
                <>
                  <div className="divider">Submit Your Work</div>
                  <div className="form-control">
                    <label className="label">
                      <span className="label-text">Submission URI</span>
                    </label>
                    <input
                      type="text"
                      className="input input-bordered bg-base-100"
                      placeholder="ipfs://... or https://..."
                      value={submissionURI}
                      onChange={e => setSubmissionURI(e.target.value)}
                    />
                  </div>
                  <button
                    className="btn btn-success mt-3"
                    onClick={handleSubmitWork}
                    disabled={isSubmitting || !submissionURI}
                  >
                    {isSubmitting ? (
                      <>
                        <span className="loading loading-spinner loading-sm"></span> Submitting...
                      </>
                    ) : (
                      "📤 Submit Work"
                    )}
                  </button>
                </>
              )}
            </div>
          </div>
        )}

        {/* Submitted - Review */}
        {statusNum === 2 && (
          <div className="card bg-base-300 shadow-xl mb-6">
            <div className="card-body">
              <h3 className="text-lg font-semibold mb-3">📋 Work Submitted — Awaiting Review</h3>
              <div className="bg-base-100 rounded-lg p-4 mb-4">
                <div className="text-xs opacity-60 mb-1">Submission URI</div>
                <a
                  href={jobSubmissionURI}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="link link-primary break-all"
                >
                  {jobSubmissionURI}
                </a>
              </div>
              <div className="bg-base-100 rounded-lg p-4 mb-4">
                <div className="text-xs opacity-60 mb-1">Agent</div>
                <Address address={agent} />
                <div className="text-xs mt-1 opacity-60">Agent ID: #{agentId}</div>
              </div>
              {isPoster && (
                <>
                  <div className="divider">Review Work</div>
                  <div className="form-control mb-3">
                    <label className="label">
                      <span className="label-text">Rating (1-5)</span>
                    </label>
                    <div className="rating rating-lg">
                      {[1, 2, 3, 4, 5].map(r => (
                        <input
                          key={r}
                          type="radio"
                          name="rating"
                          className="mask mask-star-2 bg-warning"
                          checked={parseInt(rating) === r}
                          onChange={() => setRating(String(r))}
                        />
                      ))}
                    </div>
                  </div>
                  <div className="flex gap-3">
                    <button className="btn btn-success flex-1" onClick={handleApproveWork} disabled={isApproving}>
                      {isApproving ? (
                        <>
                          <span className="loading loading-spinner loading-sm"></span> Approving...
                        </>
                      ) : (
                        "✅ Approve Work"
                      )}
                    </button>
                    <button className="btn btn-error flex-1" onClick={handleDispute} disabled={isDisputing}>
                      {isDisputing ? (
                        <>
                          <span className="loading loading-spinner loading-sm"></span> Disputing...
                        </>
                      ) : (
                        "❌ Dispute"
                      )}
                    </button>
                  </div>
                </>
              )}
            </div>
          </div>
        )}

        {/* Completed */}
        {statusNum === 3 && (
          <div className="card bg-base-300 shadow-xl mb-6">
            <div className="card-body">
              <h3 className="text-lg font-semibold mb-3">✅ Job Completed</h3>
              <div className="grid grid-cols-2 gap-4">
                <div className="bg-base-100 rounded-lg p-4">
                  <div className="text-xs opacity-60 mb-1">Agent</div>
                  <Address address={agent} />
                  <div className="text-xs mt-1 opacity-60">Agent ID: #{agentId}</div>
                </div>
                <div className="bg-base-100 rounded-lg p-4">
                  <div className="text-xs opacity-60 mb-1">Payment</div>
                  <div className="text-xl font-bold text-success">
                    {paidAmount ? parseFloat(formatEther(paidAmount)).toFixed(2) : "0"} CLAWD
                  </div>
                </div>
              </div>
              <div className="bg-base-100 rounded-lg p-4 mt-4">
                <div className="text-xs opacity-60 mb-1">Rating</div>
                <div className="rating rating-md">
                  {[1, 2, 3, 4, 5].map(r => (
                    <input
                      key={r}
                      type="radio"
                      className="mask mask-star-2 bg-warning"
                      checked={jobRating === r}
                      readOnly
                      disabled
                    />
                  ))}
                </div>
              </div>
              {jobSubmissionURI && (
                <div className="bg-base-100 rounded-lg p-4 mt-4">
                  <div className="text-xs opacity-60 mb-1">Submission</div>
                  <a
                    href={jobSubmissionURI}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="link link-primary break-all"
                  >
                    {jobSubmissionURI}
                  </a>
                </div>
              )}
            </div>
          </div>
        )}

        {/* Disputed */}
        {statusNum === 4 && (
          <div className="card bg-base-300 shadow-xl mb-6 border-2 border-error">
            <div className="card-body">
              <h3 className="text-lg font-semibold text-error mb-3">⚠️ Work Disputed</h3>
              <div className="bg-base-100 rounded-lg p-4">
                <div className="text-xs opacity-60 mb-1">Agent</div>
                <Address address={agent} />
              </div>
              {jobSubmissionURI && (
                <div className="bg-base-100 rounded-lg p-4 mt-4">
                  <div className="text-xs opacity-60 mb-1">Submission</div>
                  <a
                    href={jobSubmissionURI}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="link link-primary break-all"
                  >
                    {jobSubmissionURI}
                  </a>
                </div>
              )}
            </div>
          </div>
        )}

        {/* Price Range - always visible */}
        <div className="card bg-base-300 shadow-xl mb-6">
          <div className="card-body">
            <h3 className="text-lg font-semibold mb-3">💰 Price Details</h3>
            <div className="grid grid-cols-2 gap-4">
              <div className="bg-base-100 rounded-lg p-4">
                <div className="text-xs opacity-60 mb-1">Min Price</div>
                <div className="font-bold">{parseFloat(formatEther(minPrice)).toFixed(2)} CLAWD</div>
              </div>
              <div className="bg-base-100 rounded-lg p-4">
                <div className="text-xs opacity-60 mb-1">Max Price</div>
                <div className="font-bold">{parseFloat(formatEther(maxPrice)).toFixed(2)} CLAWD</div>
              </div>
            </div>
            <div className="grid grid-cols-2 gap-4 mt-2">
              <div className="bg-base-100 rounded-lg p-4">
                <div className="text-xs opacity-60 mb-1">Auction Duration</div>
                <div className="font-bold">{formatTimeRemaining(Number(auctionDuration))}</div>
              </div>
              <div className="bg-base-100 rounded-lg p-4">
                <div className="text-xs opacity-60 mb-1">Work Deadline</div>
                <div className="font-bold">{formatTimeRemaining(Number(workDeadline))}</div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

const JobDetailPage = () => {
  return (
    <Suspense
      fallback={
        <div className="flex justify-center items-center min-h-[50vh]">
          <span className="loading loading-spinner loading-lg"></span>
        </div>
      }
    >
      <JobDetailInner />
    </Suspense>
  );
};

export default JobDetailPage;
