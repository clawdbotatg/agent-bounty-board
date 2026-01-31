"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { Address } from "@scaffold-ui/components";
import type { NextPage } from "next";
import { formatEther } from "viem";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { JOB_STATUS_COLORS, JOB_STATUS_LABELS, formatTimeRemaining } from "~~/utils/bountyBoard";

// ─── Job Card Component ───
const JobCard = ({ jobId }: { jobId: number }) => {
  const [now, setNow] = useState(Math.floor(Date.now() / 1000));

  // Live clock for auction price
  useEffect(() => {
    const interval = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(interval);
  }, []);

  const { data: jobCore } = useScaffoldReadContract({
    contractName: "AgentBountyBoard",
    functionName: "getJobCore",
    args: [BigInt(jobId)],
  });

  const { data: currentPrice } = useScaffoldReadContract({
    contractName: "AgentBountyBoard",
    functionName: "getCurrentPrice",
    args: [BigInt(jobId)],
  });

  const { data: jobAgent } = useScaffoldReadContract({
    contractName: "AgentBountyBoard",
    functionName: "getJobAgent",
    args: [BigInt(jobId)],
  });

  if (!jobCore) return null;

  const [poster, description, minPrice, maxPrice, auctionStart, auctionDuration, workDeadline, status] = jobCore;
  const statusNum = Number(status);

  const auctionEnd = Number(auctionStart) + Number(auctionDuration);
  const auctionTimeRemaining = auctionEnd - now;
  const isAuctionActive = statusNum === 0 && auctionTimeRemaining > 0;

  return (
    <Link href={`/job?id=${jobId}`}>
      <div className="card bg-base-300 shadow-xl hover:shadow-2xl transition-all cursor-pointer h-full">
        <div className="card-body p-5">
          {/* Header row */}
          <div className="flex justify-between items-start">
            <h3 className="card-title text-sm font-bold">Job #{jobId}</h3>
            <span className={`badge ${JOB_STATUS_COLORS[statusNum]} badge-sm`}>{JOB_STATUS_LABELS[statusNum]}</span>
          </div>

          {/* Description */}
          <p className="text-sm opacity-80 line-clamp-2">{description}</p>

          {/* Price info */}
          <div className="mt-2">
            {isAuctionActive && currentPrice ? (
              <div className="bg-base-100 rounded-lg p-3">
                <div className="text-xs opacity-60 mb-1">Current Price (Dutch Auction)</div>
                <div className="text-2xl font-bold text-primary font-mono">
                  {parseFloat(formatEther(currentPrice)).toFixed(2)} CLAWD
                </div>
                <div className="flex justify-between mt-1 text-xs opacity-60">
                  <span>Max: {parseFloat(formatEther(maxPrice)).toFixed(0)}</span>
                  <span>→</span>
                  <span>Min: {parseFloat(formatEther(minPrice)).toFixed(0)}</span>
                </div>
                <div className="mt-2 text-xs">⏱ {formatTimeRemaining(auctionTimeRemaining)} remaining</div>
              </div>
            ) : statusNum === 0 ? (
              <div className="bg-base-100 rounded-lg p-3 text-sm opacity-60">Auction ended — awaiting expiry</div>
            ) : (
              <div className="bg-base-100 rounded-lg p-3">
                <div className="text-xs opacity-60 mb-1">Price Range</div>
                <div className="text-sm">
                  {parseFloat(formatEther(minPrice)).toFixed(0)} – {parseFloat(formatEther(maxPrice)).toFixed(0)} CLAWD
                </div>
                {jobAgent && Number(jobAgent[4]) > 0 && (
                  <div className="text-sm mt-1 text-success">
                    Paid: {parseFloat(formatEther(jobAgent[4])).toFixed(2)} CLAWD
                  </div>
                )}
              </div>
            )}
          </div>

          {/* Work deadline */}
          <div className="text-xs opacity-50 mt-1">Work deadline: {formatTimeRemaining(Number(workDeadline))}</div>

          {/* Poster */}
          <div className="flex items-center gap-1 mt-1 text-xs opacity-50">
            <span>By:</span>
            <Address address={poster} size="xs" />
          </div>
        </div>
      </div>
    </Link>
  );
};

// ─── Main Page ───
const Home: NextPage = () => {
  const [filter, setFilter] = useState<"all" | "open" | "claimed" | "completed">("all");

  const { data: jobCount } = useScaffoldReadContract({
    contractName: "AgentBountyBoard",
    functionName: "getJobCount",
  });

  const totalJobs = jobCount ? Number(jobCount) : 0;

  // Build job IDs array (reverse order — newest first)
  const jobIds = Array.from({ length: totalJobs }, (_, i) => totalJobs - 1 - i);

  return (
    <div className="flex flex-col grow">
      {/* Stats Banner */}
      <div className="bg-base-300 border-b border-base-200">
        <div className="max-w-7xl mx-auto px-6 py-4">
          <div className="stats stats-horizontal w-full bg-transparent">
            <div className="stat place-items-center py-2">
              <div className="stat-title text-xs">Total Jobs</div>
              <div className="stat-value text-2xl">{totalJobs}</div>
            </div>
            <div className="stat place-items-center py-2">
              <div className="stat-title text-xs">Auction Type</div>
              <div className="stat-value text-lg">🇳🇱 Dutch</div>
            </div>
            <div className="stat place-items-center py-2">
              <div className="stat-title text-xs">Token</div>
              <div className="stat-value text-lg">🐾 CLAWD</div>
            </div>
          </div>
        </div>
      </div>

      {/* Main Content */}
      <div className="max-w-7xl mx-auto px-6 py-6 w-full grow">
        {/* Filter Tabs */}
        <div className="tabs tabs-boxed mb-6 bg-base-300 inline-flex">
          {(["all", "open", "claimed", "completed"] as const).map(tab => (
            <button key={tab} className={`tab ${filter === tab ? "tab-active" : ""}`} onClick={() => setFilter(tab)}>
              {tab.charAt(0).toUpperCase() + tab.slice(1)}
            </button>
          ))}
        </div>

        {/* Jobs Grid */}
        {totalJobs === 0 ? (
          <div className="text-center py-20 opacity-50">
            <div className="text-6xl mb-4">📋</div>
            <p className="text-xl">No jobs posted yet</p>
            <Link href="/post" className="btn btn-primary mt-4">
              Post the First Job
            </Link>
          </div>
        ) : (
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            {jobIds.map(id => (
              <FilteredJobCard key={id} jobId={id} filter={filter} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
};

// ─── Filtered Job Card (handles filtering) ───
const FilteredJobCard = ({ jobId, filter }: { jobId: number; filter: "all" | "open" | "claimed" | "completed" }) => {
  const { data: jobCore } = useScaffoldReadContract({
    contractName: "AgentBountyBoard",
    functionName: "getJobCore",
    args: [BigInt(jobId)],
  });

  if (!jobCore) return null;

  const statusNum = Number(jobCore[7]);

  if (filter === "open" && statusNum !== 0) return null;
  if (filter === "claimed" && statusNum !== 1) return null;
  if (filter === "completed" && statusNum !== 3) return null;

  return <JobCard jobId={jobId} />;
};

export default Home;
