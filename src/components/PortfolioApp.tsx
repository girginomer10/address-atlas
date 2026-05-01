"use client";

import { useEffect, useMemo, useState } from "react";
import {
  Activity,
  AlertCircle,
  ArrowUpRight,
  ClipboardPaste,
  Database,
  Loader2,
  Map as MapIcon,
  RefreshCcw,
  ShieldCheck,
  Wallet
} from "lucide-react";
import { percent, shortAddress, toUsd } from "@/lib/format";
import { ScanResponse, TrackedAsset } from "@/lib/types";

const STORAGE_KEY = "address-atlas-input";

export function PortfolioApp() {
  const [input, setInput] = useState("");
  const [data, setData] = useState<ScanResponse | null>(null);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    setInput(window.localStorage.getItem(STORAGE_KEY) ?? "");
  }, []);

  useEffect(() => {
    window.localStorage.setItem(STORAGE_KEY, input);
  }, [input]);

  const allocations = useMemo(() => {
    const totals = new Map<string, number>();
    data?.assets.forEach((asset) => {
      totals.set(asset.chainName, (totals.get(asset.chainName) ?? 0) + asset.valueUsd);
    });

    return Array.from(totals.entries())
      .map(([name, value]) => ({
        name,
        value,
        share: data?.summary.totalUsd ? (value / data.summary.totalUsd) * 100 : 0
      }))
      .sort((a, b) => b.value - a.value);
  }, [data]);

  async function scan() {
    setError("");
    setLoading(true);

    try {
      const response = await fetch("/api/scan", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ addresses: input })
      });
      const body = await response.json();
      if (!response.ok) {
        throw new Error(body.error || "Scan failed");
      }
      setData(body);
    } catch (scanError) {
      setError(scanError instanceof Error ? scanError.message : "Scan failed");
    } finally {
      setLoading(false);
    }
  }

  function loadSample() {
    setInput(
      [
        "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
        "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh",
        "cosmos1p8s5k7eyed68x2qplfw0e5a8svjqx39g7yr82m"
      ].join("\n")
    );
  }

  const total = data?.summary.totalUsd ?? 0;

  return (
    <main className="shell">
      <header className="topbar">
        <div className="brand">
          <div className="brandMark" aria-hidden="true">
            <MapIcon size={22} />
          </div>
          <div>
            <h1>Address Atlas</h1>
            <p>Read-only portfolio map</p>
          </div>
        </div>
        <div className="trustBadge">
          <ShieldCheck size={16} />
          <span>No keys</span>
        </div>
      </header>

      <section className="workspace">
        <div className="scanPanel">
          <div className="panelHeader">
            <div>
              <h2>Wallet Scan</h2>
              <p>BTC, EVM and Cosmos addresses</p>
            </div>
            <button className="iconButton" type="button" onClick={loadSample} aria-label="Load sample">
              <ClipboardPaste size={18} />
            </button>
          </div>

          <textarea
            value={input}
            onChange={(event) => setInput(event.target.value)}
            spellCheck={false}
            placeholder={"0x...\nbc1...\ncosmos1..."}
            className="addressInput"
          />

          {error && (
            <div className="errorLine">
              <AlertCircle size={16} />
              <span>{error}</span>
            </div>
          )}

          <div className="actions">
            <button className="primaryButton" type="button" onClick={scan} disabled={loading || !input.trim()}>
              {loading ? <Loader2 className="spin" size={18} /> : <Activity size={18} />}
              <span>{loading ? "Scanning" : "Scan"}</span>
            </button>
            <button className="secondaryButton" type="button" onClick={scan} disabled={loading || !data}>
              <RefreshCcw size={17} />
              <span>Refresh</span>
            </button>
          </div>
        </div>

        <div className="summaryPanel">
          <div className="totalBlock">
            <span>Total Value</span>
            <strong>{toUsd(total)}</strong>
          </div>

          <div className="metricGrid">
            <Metric icon={<Wallet size={18} />} label="Addresses" value={data?.summary.addressCount ?? 0} />
            <Metric icon={<Database size={18} />} label="Assets" value={data?.summary.assetCount ?? 0} />
            <Metric icon={<MapIcon size={18} />} label="Chains" value={data?.summary.chainCount ?? 0} />
          </div>

          <div className="allocationList">
            {allocations.length === 0 ? (
              <div className="emptyState">Paste addresses to build an atlas.</div>
            ) : (
              allocations.map((item, index) => (
                <div className="allocationRow" key={item.name}>
                  <div className="allocationLabel">
                    <span>{item.name}</span>
                    <strong>{toUsd(item.value)}</strong>
                  </div>
                  <div className="track">
                    <div
                      className={`fill fill${index % 5}`}
                      style={{ width: `${Math.max(item.share, 3)}%` }}
                    />
                  </div>
                </div>
              ))
            )}
          </div>
        </div>
      </section>

      <section className="results">
        <div className="sectionTitle">
          <h2>Assets</h2>
          <span>{data?.generatedAt ? new Date(data.generatedAt).toLocaleTimeString() : "Ready"}</span>
        </div>

        <AssetTable assets={data?.assets ?? []} />

        {!!data?.warnings.length && (
          <div className="warnings">
            {data.warnings.slice(0, 6).map((warning) => (
              <div key={warning}>
                <AlertCircle size={15} />
                <span>{warning}</span>
              </div>
            ))}
          </div>
        )}
      </section>
    </main>
  );
}

function Metric({
  icon,
  label,
  value
}: {
  icon: React.ReactNode;
  label: string;
  value: number;
}) {
  return (
    <div className="metric">
      {icon}
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  );
}

function AssetTable({ assets }: { assets: TrackedAsset[] }) {
  if (assets.length === 0) {
    return (
      <div className="assetEmpty">
        <Wallet size={28} />
        <span>No balances yet</span>
      </div>
    );
  }

  return (
    <div className="tableWrap">
      <table>
        <thead>
          <tr>
            <th>Asset</th>
            <th>Chain</th>
            <th>Address</th>
            <th className="num">Amount</th>
            <th className="num">24h</th>
            <th className="num">Value</th>
            <th aria-label="Explorer" />
          </tr>
        </thead>
        <tbody>
          {assets
            .slice()
            .sort((a, b) => b.valueUsd - a.valueUsd)
            .map((asset) => (
              <tr key={asset.id}>
                <td>
                  <div className="assetName">
                    <span>{asset.symbol}</span>
                    <small>{asset.source === "erc20" ? asset.name : "Native"}</small>
                  </div>
                </td>
                <td>{asset.chainName}</td>
                <td className="mono">{shortAddress(asset.address)}</td>
                <td className="num mono">{asset.amount.toLocaleString(undefined, { maximumFractionDigits: 6 })}</td>
                <td className={`num ${asset.change24h && asset.change24h < 0 ? "down" : "up"}`}>
                  {percent(asset.change24h)}
                </td>
                <td className="num strong">{toUsd(asset.valueUsd)}</td>
                <td className="num">
                  <a href={asset.explorerUrl} target="_blank" rel="noreferrer" aria-label={`Open ${asset.symbol} explorer`}>
                    <ArrowUpRight size={16} />
                  </a>
                </td>
              </tr>
            ))}
        </tbody>
      </table>
    </div>
  );
}
