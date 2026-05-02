"use client";

import Link from "next/link";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState
} from "react";
import type { ReactNode } from "react";
import {
  ArrowDownToLine,
  ArrowUpRight,
  Check,
  Copy,
  Database,
  Download,
  Eye,
  EyeOff,
  Loader2,
  Menu,
  Pencil,
  Plus,
  RefreshCcw,
  Search,
  ShieldCheck,
  Trash2,
  Wallet,
  X
} from "lucide-react";
import { percent, toMoney } from "@/lib/format";
import { assetsToCsv, scanToJson, timestampForFile } from "@/lib/export";
import { ExchangeProvider, ScanResponse, TrackedAsset } from "@/lib/types";

type ScanHistoryEntry = {
  id: string;
  generatedAt: string;
  totalUsd: number;
  inputCount: number;
  assetCount: number;
  chainCount: number;
  warningCount: number;
  sourceCount: number;
  topChains: { name: string; valueUsd: number }[];
};

type FxResponse = {
  base: string;
  generatedAt: string;
  supported: readonly string[];
  rates: Record<string, number>;
};

const MoneyContext = createContext<{ currency: string; rates: Record<string, number> }>({
  currency: "USD",
  rates: { USD: 1 }
});

function useMoney() {
  const { currency, rates } = useContext(MoneyContext);
  return useMemo(
    () => {
      const requested = currency.toUpperCase();
      const rate = rates[requested];
      const effective = Number.isFinite(rate) && (rate as number) > 0 ? requested : "USD";
      return {
        currency,
        effectiveCurrency: effective,
        rates,
        format: (value: number) => toMoney(value, currency, rates)
      };
    },
    [currency, rates]
  );
}

const AUTO_REFRESH_INTERVAL_MS = 5 * 60_000;

function sameRates(left: Record<string, number>, right: Record<string, number>) {
  const leftKeys = Object.keys(left);
  const rightKeys = Object.keys(right);
  return leftKeys.length === rightKeys.length && rightKeys.every((key) => left[key] === right[key]);
}

type ActivePage = "portfolio" | "wallets" | "assets" | "snapshots" | "export" | "settings";

type WalletRecord = {
  id: string;
  label: string;
  address: string;
  chainKind: string;
  createdAt: string;
  updatedAt: string;
};

type PreferenceRecord = {
  darkMode: boolean;
  density: "compact" | "comfy";
  mono: boolean;
  hideDust: boolean;
  dustThreshold: number;
  autoRefresh: boolean;
  currency: string;
};

type ExchangeConnection = {
  id: string;
  provider: ExchangeProvider;
  providerLabel: string;
  label: string;
  status: string;
  lastTestedAt?: string;
  lastSyncAt?: string;
  lastError?: string;
};

type ExchangeProviderOption = {
  id: ExchangeProvider;
  label: string;
};

type CustomTokenRecord = {
  id: string;
  chainKind: string;
  chainId: string;
  address: string;
  symbol: string;
  name: string;
  decimals: number;
  coinGeckoId: string;
  enabled: boolean;
  createdAt: string;
  updatedAt: string;
};

type TokenChainOption = {
  id: string;
  name: string;
  family: string;
};

const EMPTY_TOKEN_FORM = {
  chainId: "ethereum",
  address: "",
  symbol: "",
  name: "",
  decimals: "18",
  coinGeckoId: ""
};

type ManualProvider = ExchangeProvider | "custom";

type ManualProviderOption = {
  id: ManualProvider;
  label: string;
};

type ManualHoldingRecord = {
  id: string;
  label: string;
  provider: ManualProvider;
  providerLabel: string;
  customVenue: string | null;
  symbol: string;
  name: string;
  amount: number;
  priceUsd: number | null;
  valueUsd: number;
  notes: string | null;
  enabled: boolean;
  generatedAt: string;
  createdAt: string;
  updatedAt: string;
};

const STORAGE_KEY = "address-atlas-input";
const DEFAULT_PREFS: PreferenceRecord = {
  darkMode: false,
  density: "comfy",
  mono: false,
  hideDust: false,
  dustThreshold: 5,
  autoRefresh: true,
  currency: "USD"
};

const NAV_ITEMS: { id: ActivePage; label: string; href: string }[] = [
  { id: "portfolio", label: "Portfolio", href: "/" },
  { id: "wallets", label: "Wallets", href: "/wallets" },
  { id: "assets", label: "Assets", href: "/assets" },
  { id: "snapshots", label: "Snapshots", href: "/snapshots" },
  { id: "export", label: "Export", href: "/export" },
  { id: "settings", label: "Settings", href: "/settings" }
];

const TRUST_POINTS = ["No private keys", "Read-only scanning", "Public data only", "No signing - no custody"];

const SAMPLE_ADDRESSES = [
  "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
  "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh",
  "cosmos1p8s5k7eyed68x2qplfw0e5a8svjqx39g7yr82m",
  "So11111111111111111111111111111111111111112"
].join("\n");

export function AddressAtlasApp({ active }: { active: ActivePage }) {
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [rawText, setRawText] = useState("");
  const [wallets, setWallets] = useState<WalletRecord[]>([]);
  const [scan, setScan] = useState<ScanResponse | null>(null);
  const [prefs, setPrefs] = useState<PreferenceRecord>(DEFAULT_PREFS);
  const [connections, setConnections] = useState<ExchangeConnection[]>([]);
  const [providers, setProviders] = useState<ExchangeProviderOption[]>([]);
  const [customTokens, setCustomTokens] = useState<CustomTokenRecord[]>([]);
  const [tokenChains, setTokenChains] = useState<TokenChainOption[]>([]);
  const [manualHoldings, setManualHoldings] = useState<ManualHoldingRecord[]>([]);
  const [manualProviders, setManualProviders] = useState<ManualProviderOption[]>([]);
  const [vaultReady, setVaultReady] = useState(false);
  const [vaultPassphrase, setVaultPassphrase] = useState("");
  const [history, setHistory] = useState<ScanHistoryEntry[]>([]);
  const [historyLoaded, setHistoryLoaded] = useState(false);
  const [loading, setLoading] = useState(true);
  const [scanning, setScanning] = useState(false);
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");
  const [fxRates, setFxRates] = useState<Record<string, number>>({ USD: 1 });

  const scanningRef = useRef(false);
  const walletsRef = useRef(wallets);
  const connectionsRef = useRef(connections);
  const vaultPassphraseRef = useRef(vaultPassphrase);
  const rawTextRef = useRef(rawText);

  useEffect(() => {
    scanningRef.current = scanning;
  }, [scanning]);
  useEffect(() => {
    walletsRef.current = wallets;
  }, [wallets]);
  useEffect(() => {
    connectionsRef.current = connections;
  }, [connections]);
  useEffect(() => {
    vaultPassphraseRef.current = vaultPassphrase;
  }, [vaultPassphrase]);
  useEffect(() => {
    rawTextRef.current = rawText;
  }, [rawText]);

  useEffect(() => {
    setRawText(window.localStorage.getItem(STORAGE_KEY) ?? "");
    void refresh();
    void loadFxRates();
  }, []);

  useEffect(() => {
    window.localStorage.setItem(STORAGE_KEY, rawText);
  }, [rawText]);

  useEffect(() => {
    document.documentElement.dataset.theme = prefs.darkMode ? "dark" : "light";
    document.documentElement.dataset.density = prefs.density;
    document.documentElement.dataset.mono = prefs.mono ? "1" : "0";
  }, [prefs]);

  useEffect(() => {
    if (prefs.currency === "USD") return;
    if (fxRates[prefs.currency]) return;
    void loadFxRates();
  }, [prefs.currency, fxRates]);

  async function loadFxRates() {
    try {
      const body = await fetchJson<FxResponse>("/api/fx");
      if (body?.rates && typeof body.rates === "object") {
        const nextRates = { USD: 1, ...body.rates };
        setFxRates((prev) => (sameRates(prev, nextRates) ? prev : nextRates));
      }
    } catch {
      setFxRates((prev) => (prev.USD === 1 && Object.keys(prev).length > 0 ? prev : { USD: 1 }));
    }
  }

  async function refresh() {
    setLoading(true);
    setError("");
    try {
      const [walletBody, scanBody, preferenceBody, exchangeBody, tokenBody, manualBody, historyBody] = await Promise.all([
        fetchJson<{ wallets: WalletRecord[] }>("/api/wallets"),
        fetchJson<ScanResponse | null>("/api/scan"),
        fetchJson<PreferenceRecord>("/api/preferences"),
        fetchJson<{
          providers: ExchangeProviderOption[];
          vaultReady: boolean;
          connections: ExchangeConnection[];
        }>("/api/exchanges"),
        fetchJson<{ tokens: CustomTokenRecord[]; chainOptions: TokenChainOption[] }>("/api/tokens"),
        fetchJson<{
          providers: ManualProviderOption[];
          holdings: ManualHoldingRecord[];
        }>("/api/exchanges/manual"),
        fetchJson<{ entries: ScanHistoryEntry[] }>("/api/scan/history")
      ]);
      setWallets(walletBody.wallets);
      setScan(scanBody);
      setPrefs({ ...DEFAULT_PREFS, ...preferenceBody });
      setProviders(exchangeBody.providers);
      setVaultReady(exchangeBody.vaultReady);
      setConnections(exchangeBody.connections);
      setCustomTokens(tokenBody.tokens);
      setTokenChains(tokenBody.chainOptions);
      setManualProviders(manualBody.providers);
      setManualHoldings(manualBody.holdings);
      setHistory(historyBody.entries);
      setHistoryLoaded(true);
    } catch (refreshError) {
      setError(readError(refreshError));
    } finally {
      setLoading(false);
    }
  }

  const runScan = useCallback(
    async (options?: { savedOnly?: boolean; includeExchanges?: boolean; silent?: boolean }) => {
      if (scanningRef.current) return;
      scanningRef.current = true;
      setScanning(true);
      if (!options?.silent) {
        setError("");
        setNotice("");
      }

      try {
        const currentWallets = walletsRef.current;
        const currentConnections = connectionsRef.current;
        const currentVault = vaultPassphraseRef.current;
        const currentRaw = rawTextRef.current;

        const body = {
          addresses: options?.savedOnly ? "" : currentRaw,
          walletIds: options?.savedOnly ? currentWallets.map((wallet) => wallet.id) : [],
          includeExchanges: options?.includeExchanges ?? currentConnections.length > 0,
          vaultPassphrase: currentVault || undefined
        };
        const nextScan = await fetchJson<ScanResponse>("/api/scan", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(body)
        });
        setScan(nextScan);
        if (!options?.silent) {
          setNotice(`Scan complete: ${nextScan.summary.assetCount} holdings indexed.`);
        }
        await refresh();
      } catch (scanError) {
        if (!options?.silent) {
          setError(readError(scanError));
        }
      } finally {
        scanningRef.current = false;
        setScanning(false);
      }
    },
    []
  );

  useEffect(() => {
    if (!prefs.autoRefresh) return;

    const interval = setInterval(() => {
      const currentWallets = walletsRef.current;
      if (currentWallets.length === 0) return;
      if (scanningRef.current) return;

      const hasExchanges = connectionsRef.current.length > 0;
      const hasVault = Boolean(vaultPassphraseRef.current);
      const includeExchanges = hasExchanges && hasVault;

      void runScan({ savedOnly: true, includeExchanges, silent: true });
    }, AUTO_REFRESH_INTERVAL_MS);

    return () => {
      clearInterval(interval);
    };
  }, [prefs.autoRefresh, runScan]);

  async function savePrefs(next: Partial<PreferenceRecord>) {
    const optimistic = { ...prefs, ...next };
    setPrefs(optimistic);
    try {
      setPrefs(await fetchJson<PreferenceRecord>("/api/preferences", {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(next)
      }));
    } catch (preferenceError) {
      setError(readError(preferenceError));
    }
  }

  const context = {
    rawText,
    setRawText,
    wallets,
    scan,
    prefs,
    setPrefs: savePrefs,
    connections,
    providers,
    manualHoldings,
    manualProviders,
    vaultReady,
    vaultPassphrase,
    setVaultPassphrase,
    customTokens,
    tokenChains,
    history,
    historyLoaded,
    loading,
    scanning,
    notice,
    error,
    refresh,
    runScan
  };

  return (
    <MoneyContext.Provider value={{ currency: prefs.currency, rates: fxRates }}>
      <div className="aa-shell">
        <Sidebar active={active} />
        <MobileBar active={active} onOpen={() => setDrawerOpen(true)} />
        <MobileDrawer active={active} open={drawerOpen} onClose={() => setDrawerOpen(false)} />
        <main className="aa-main">
          {active === "portfolio" && <PortfolioPage {...context} />}
          {active === "wallets" && <WalletsPage {...context} />}
          {active === "assets" && <AssetsPage {...context} />}
          {active === "snapshots" && <SnapshotsPage {...context} />}
          {active === "export" && <ExportPage {...context} />}
          {active === "settings" && <SettingsPage {...context} />}
          <Footer />
        </main>
      </div>
    </MoneyContext.Provider>
  );
}

function Sidebar({ active }: { active: ActivePage }) {
  return (
    <aside className="aa-sidebar">
      <Link className="aa-brand" href="/">
        <span className="aa-mark">∞</span>
        <span>
          <span className="aa-name">Address Atlas</span>
          <span className="aa-sub">Read-only crypto archive</span>
        </span>
      </Link>
      <NavLinks active={active} />
      <div className="aa-sidebar-foot">
        {TRUST_POINTS.map((point) => (
          <span key={point}>
            <i /> {point}
          </span>
        ))}
        <small>Local-first · v0.5.0</small>
      </div>
    </aside>
  );
}

function MobileBar({ active, onOpen }: { active: ActivePage; onOpen: () => void }) {
  const current = NAV_ITEMS.find((item) => item.id === active);
  return (
    <header className="aa-mobilebar">
      <Link className="aa-mobile-brand" href="/">
        <span className="aa-mark">∞</span>
        <span>Address Atlas</span>
      </Link>
      <button className="aa-mobile-toggle" type="button" onClick={onOpen} aria-label="Open navigation">
        <span>{current?.label ?? "Menu"}</span>
        <Menu size={17} />
      </button>
    </header>
  );
}

function MobileDrawer({
  active,
  open,
  onClose
}: {
  active: ActivePage;
  open: boolean;
  onClose: () => void;
}) {
  return (
    <>
      <button
        className={`aa-drawer-bg ${open ? "on" : ""}`}
        type="button"
        aria-label="Close navigation"
        onClick={onClose}
      />
      <aside className={`aa-drawer ${open ? "on" : ""}`}>
        <div className="aa-drawer-head">
          <span>Navigation</span>
          <button type="button" onClick={onClose} aria-label="Close">
            <X size={17} />
          </button>
        </div>
        <NavLinks active={active} onClick={onClose} />
      </aside>
    </>
  );
}

function NavLinks({ active, onClick }: { active: ActivePage; onClick?: () => void }) {
  return (
    <nav className="aa-nav">
      {NAV_ITEMS.map((item) => (
        <Link key={item.id} className={`aa-nav-link ${active === item.id ? "on" : ""}`} href={item.href} onClick={onClick}>
          <span>{item.label}</span>
          {active === item.id && <b>/</b>}
        </Link>
      ))}
    </nav>
  );
}

function PageHead({
  section,
  title,
  lede,
  right,
  actions,
  compact
}: {
  section: string;
  title: ReactNode;
  lede?: string;
  right?: ReactNode;
  actions?: ReactNode;
  compact?: boolean;
}) {
  return (
    <header className={`aa-page-head ${compact ? "compact" : ""}`}>
      <div className="aa-eyebrow">{section}</div>
      <div className="aa-page-row">
        <h1>{title}</h1>
        {right && <div className="aa-head-right">{right}</div>}
      </div>
      {lede && <p>{lede}</p>}
      {actions && <div className="aa-head-actions">{actions}</div>}
    </header>
  );
}

function PortfolioPage(props: AppContext) {
  const { scan, wallets, rawText, setRawText, scanning, runScan, notice, error, connections, vaultPassphrase, setVaultPassphrase } = props;
  const money = useMoney();
  const assets = filteredAssets(scan?.assets ?? [], props.prefs);
  const total = assets.reduce((sum, asset) => sum + asset.valueUsd, 0);
  const allocation = allocationByChain(assets);

  return (
    <>
      <PageHead
        section="Portfolio"
        title={<>Your portfolio, <em>across chains.</em></>}
        lede="A read-only ledger of every asset across every wallet and exchange connection you've added."
        right={<HeadStats items={[["Last refresh", scan ? relativeTime(scan.generatedAt) : "Never"], ["Sources", "RPC · CoinGecko · CCXT"]]} />}
      />
      <section className="aa-dash-intake">
        <PasteBox
          rawText={rawText}
          setRawText={setRawText}
          scanning={scanning}
          onScan={() => runScan({ includeExchanges: connections.length > 0 })}
          onLoadSample={() => setRawText(SAMPLE_ADDRESSES)}
        />
        <div className="aa-right-rail">
          <span className="aa-section-title">Quick actions</span>
          <Link href="/wallets">Manage {wallets.length} watched wallets <ArrowUpRight size={15} /></Link>
          <Link href="/export">Export CSV / JSON <ArrowDownToLine size={15} /></Link>
          <Link href="/snapshots">Connect exchanges <Plus size={15} /></Link>
          {connections.length > 0 && (
            <label className="aa-vault-inline">
              <span>Vault passphrase</span>
              <input
                value={vaultPassphrase}
                onChange={(event) => setVaultPassphrase(event.target.value)}
                type="password"
                placeholder="Required for exchange scans"
              />
            </label>
          )}
        </div>
      </section>
      <StatusLine notice={notice} error={error} scanning={scanning} />
      <section className="aa-portfolio-top">
        <div>
          <div className="aa-totalblock">
            <span className="aa-label">Total portfolio value ({money.effectiveCurrency})</span>
            <strong>{money.format(total)}</strong>
            <small>{assets.length} holdings · {wallets.length} wallets · {connections.length} exchanges</small>
          </div>
          <div className="aa-metrics">
            <Metric label="Wallets" value={wallets.length} />
            <Metric label="Chains" value={allocation.length} />
            <Metric label="Assets" value={assets.length} />
          </div>
        </div>
        <AllocationPanel allocation={allocation} total={total} />
      </section>
      <div className="aa-section-head">
        <span className="aa-section-title">Top holdings</span>
        <Link className="aa-text-link" href="/assets">View all assets</Link>
      </div>
      <AssetTable assets={assets.slice(0, 8)} wallets={wallets} hideControls />
    </>
  );
}

function WalletsPage(props: AppContext) {
  const { wallets, scan, refresh } = props;
  const money = useMoney();
  const [query, setQuery] = useState("");
  const totals = useMemo(() => totalsByWallet(scan?.assets ?? [], wallets), [scan, wallets]);
  const filtered = wallets.filter((wallet) => {
    const q = query.toLowerCase();
    return !q || wallet.label.toLowerCase().includes(q) || wallet.address.toLowerCase().includes(q) || wallet.chainKind.includes(q);
  });

  async function rename(wallet: WalletRecord) {
    const label = window.prompt("Wallet label", wallet.label);
    if (!label) return;
    await fetchJson("/api/wallets", {
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ id: wallet.id, label })
    });
    await refresh();
  }

  async function remove(wallet: WalletRecord) {
    if (!window.confirm(`Remove ${wallet.label}?`)) return;
    await fetchJson(`/api/wallets?id=${encodeURIComponent(wallet.id)}`, { method: "DELETE" });
    await refresh();
  }

  return (
    <>
      <PageHead
        compact
        section="Wallets"
        title="Watched addresses"
        lede="Public addresses saved for tracking. Rename, copy, remove, or jump to the explorer."
        right={<HeadStats items={[["Watched", wallets.length], [`Combined value (${money.effectiveCurrency})`, money.format(sumValues(scan?.assets ?? []))]]} />}
        actions={<button className="aa-btn primary" type="button" onClick={() => props.runScan({ savedOnly: true, includeExchanges: false })}>Scan saved wallets</button>}
      />
      <Toolbar query={query} setQuery={setQuery} meta={`${filtered.length} of ${wallets.length}`} placeholder="Filter by label, address or chain..." />
      {filtered.length === 0 ? <EmptyState title="No wallets yet" sub="Paste an address on the Portfolio page to begin." /> : (
        <div className="aa-wallet-list">
          {filtered.map((wallet, index) => {
            const total = totals.get(wallet.id) ?? 0;
            return (
              <article className="aa-wallet-card" key={wallet.id}>
                <span className="seq">{String(index + 1).padStart(2, "0")}</span>
                <div className="wallet-main">
                  <div className="label-line">
                    <strong>{wallet.label}</strong>
                    <span>{wallet.chainKind}</span>
                  </div>
                  <code>{wallet.address}</code>
                  <small>Added {dateOnly(wallet.createdAt)} · Last scan {scan ? relativeTime(scan.generatedAt) : "never"}</small>
                </div>
                <div className="wallet-value">
                  <strong>{money.format(total)}</strong>
                  <div>
                    <button type="button" onClick={() => rename(wallet)}>Rename</button>
                    <button type="button" onClick={() => copyText(wallet.address)}>Copy</button>
                    <a href={explorerForWallet(wallet)} target="_blank" rel="noreferrer">Explorer</a>
                    <button type="button" className="danger" onClick={() => remove(wallet)}>Remove</button>
                  </div>
                </div>
              </article>
            );
          })}
        </div>
      )}
    </>
  );
}

function AssetsPage(props: AppContext) {
  const money = useMoney();
  const assets = filteredAssets(props.scan?.assets ?? [], props.prefs);
  return (
    <>
      <PageHead
        compact
        section="Assets"
        title="Holdings index"
        lede="One row per asset, per chain, per wallet or exchange. Sort, filter, and open explorers where available."
        right={<HeadStats items={[["Lines", assets.length], [`Sum (${money.effectiveCurrency})`, money.format(sumValues(assets))]]} />}
        actions={<button className="aa-btn primary" type="button" onClick={() => downloadCsv(assets)}>Export filtered</button>}
      />
      <AssetTable assets={assets} wallets={props.wallets} />
    </>
  );
}

function SnapshotsPage(props: AppContext) {
  const {
    connections,
    providers,
    vaultReady,
    vaultPassphrase,
    setVaultPassphrase,
    refresh,
    runScan,
    scan,
    history,
    historyLoaded,
    scanning
  } = props;
  const money = useMoney();
  const [form, setForm] = useState({
    provider: "binance" as ExchangeProvider,
    label: "",
    apiKey: "",
    secret: "",
    passphrase: "",
    vaultPassphrase: ""
  });
  const [testing, setTesting] = useState(false);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState("");

  async function testOnly() {
    setTesting(true);
    setMessage("");
    try {
      const body = await fetchJson<{ result: { holdingCount: number; totalUsd: number } }>("/api/exchanges/test", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(form)
      });
      setMessage(`Connection ok: ${body.result.holdingCount} balances, ${money.format(body.result.totalUsd)}.`);
    } catch (testError) {
      setMessage(readError(testError));
    } finally {
      setTesting(false);
    }
  }

  async function saveConnection() {
    setSaving(true);
    setMessage("");
    try {
      await fetchJson("/api/exchanges", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(form)
      });
      setForm({ provider: "binance", label: "", apiKey: "", secret: "", passphrase: "", vaultPassphrase: "" });
      setMessage("Exchange connection saved.");
      await refresh();
    } catch (saveError) {
      setMessage(readError(saveError));
    } finally {
      setSaving(false);
    }
  }

  async function removeConnection(id: string) {
    if (!window.confirm("Remove this exchange connection?")) return;
    await fetchJson(`/api/exchanges?id=${encodeURIComponent(id)}`, { method: "DELETE" });
    await refresh();
  }

  const latestSnapshot = history[0];
  const previousSnapshot = history[1];
  const totalDelta = latestSnapshot && previousSnapshot ? latestSnapshot.totalUsd - previousSnapshot.totalUsd : 0;
  const totalDeltaPercent = latestSnapshot && previousSnapshot && previousSnapshot.totalUsd > 0
    ? (totalDelta / previousSnapshot.totalUsd) * 100
    : undefined;

  return (
    <>
      <PageHead
        compact
        section="Snapshots"
        title="Snapshots & exchanges"
        lede="A timeline of saved scan runs alongside the read-only exchange connections that feed them. Snapshots reflect the values reported at scan time."
        right={<HeadStats items={[
          ["Snapshots", history.length],
          ["Latest", latestSnapshot ? money.format(latestSnapshot.totalUsd) : "—"],
          ["Connections", connections.length],
          ["Vault", vaultReady ? "Ready" : "New"]
        ]} />}
        actions={<button className="aa-btn primary" type="button" onClick={() => runScan({ savedOnly: true, includeExchanges: connections.length > 0 })}>Take snapshot now</button>}
      />
      <SnapshotHistorySection
        history={history}
        historyLoaded={historyLoaded}
        scanning={scanning}
        totalDelta={totalDelta}
        totalDeltaPercent={totalDeltaPercent}
      />
      <div className="aa-section-head">
        <span className="aa-section-title">Exchange connections</span>
        <span className="aa-section-meta">{connections.length} saved · vault {vaultReady ? "ready" : "new"}</span>
      </div>
      <div className="aa-exchange-banner">
        <ShieldCheck size={18} />
        <span>Use API keys with balance/read permission only. Trading and withdrawal permissions are never needed.</span>
      </div>
      <section className="aa-exchange-grid">
        <div className="aa-exchange-form">
          <span className="aa-section-title">Guided wizard</span>
          <select value={form.provider} onChange={(event) => setForm({ ...form, provider: event.target.value as ExchangeProvider })}>
            {providers.map((provider) => <option key={provider.id} value={provider.id}>{provider.label}</option>)}
          </select>
          <input value={form.label} onChange={(event) => setForm({ ...form, label: event.target.value })} placeholder="Label, e.g. Binance main" />
          <input value={form.apiKey} onChange={(event) => setForm({ ...form, apiKey: event.target.value })} placeholder="API key" />
          <input value={form.secret} onChange={(event) => setForm({ ...form, secret: event.target.value })} placeholder="API secret" type="password" />
          <input value={form.passphrase} onChange={(event) => setForm({ ...form, passphrase: event.target.value })} placeholder="Passphrase (Coinbase only, if needed)" type="password" />
          <input value={form.vaultPassphrase} onChange={(event) => setForm({ ...form, vaultPassphrase: event.target.value })} placeholder="Vault passphrase (min 8 chars)" type="password" />
          <div className="aa-form-actions">
            <button className="aa-btn ghost" type="button" onClick={testOnly} disabled={testing}>{testing ? <Loader2 className="spin" size={15} /> : <Eye size={15} />} Test</button>
            <button className="aa-btn primary" type="button" onClick={saveConnection} disabled={saving}>{saving ? <Loader2 className="spin" size={15} /> : <Check size={15} />} Save encrypted</button>
          </div>
          {message && <p className="aa-form-message">{message}</p>}
        </div>
        <div className="aa-exchange-list">
          <span className="aa-section-title">Saved connections</span>
          <label className="aa-vault-inline">
            <span>Vault passphrase for scans</span>
            <input value={vaultPassphrase} onChange={(event) => setVaultPassphrase(event.target.value)} type="password" placeholder="Not stored" />
          </label>
          {connections.length === 0 ? <EmptyState title="No exchanges connected" sub="Add a read-only API key to include CEX balances." /> : connections.map((connection) => (
            <article className="aa-exchange-card" key={connection.id}>
              <div>
                <strong>{connection.label}</strong>
                <span>{connection.providerLabel} · {connection.status}</span>
              </div>
              <small>{connection.lastSyncAt ? `Last sync ${relativeTime(connection.lastSyncAt)}` : "Not synced yet"}</small>
              {connection.lastError && <em>{connection.lastError}</em>}
              <button type="button" onClick={() => removeConnection(connection.id)}><Trash2 size={14} /> Remove</button>
            </article>
          ))}
        </div>
      </section>
      <ManualHoldingsPanel
        holdings={props.manualHoldings}
        providers={props.manualProviders}
        refresh={refresh}
      />
      <div className="aa-section-head">
        <span className="aa-section-title">Latest exchange holdings</span>
        <span className="aa-section-meta">{scan?.exchangeSnapshots?.length ?? 0} API snapshots · {props.manualHoldings.filter((holding) => holding.enabled).length} manual</span>
      </div>
      <AssetTable assets={(scan?.assets ?? []).filter((asset) => asset.source === "exchange")} wallets={props.wallets} hideControls />
    </>
  );
}

function ManualHoldingsPanel({
  holdings,
  providers,
  refresh
}: {
  holdings: ManualHoldingRecord[];
  providers: ManualProviderOption[];
  refresh: () => Promise<void>;
}) {
  const money = useMoney();
  const initialForm = makeBlankManualForm(providers);
  const [form, setForm] = useState(initialForm);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const enabledCount = holdings.filter((holding) => holding.enabled).length;
  const disabledCount = holdings.length - enabledCount;
  const totalUsd = holdings
    .filter((holding) => holding.enabled)
    .reduce((sum, holding) => sum + holding.valueUsd, 0);

  function resetForm() {
    setForm(makeBlankManualForm(providers));
    setEditingId(null);
  }

  function startEdit(holding: ManualHoldingRecord) {
    setEditingId(holding.id);
    setForm({
      label: holding.label,
      provider: holding.provider,
      customVenue: holding.customVenue ?? "",
      symbol: holding.symbol,
      name: holding.name,
      amount: String(holding.amount),
      priceUsd: holding.priceUsd !== null ? String(holding.priceUsd) : "",
      valueUsd: String(holding.valueUsd),
      notes: holding.notes ?? ""
    });
    setMessage("");
  }

  async function submit() {
    setBusy(true);
    setMessage("");
    try {
      const payload = {
        label: form.label,
        provider: form.provider,
        customVenue: form.provider === "custom" ? form.customVenue : null,
        symbol: form.symbol,
        name: form.name,
        amount: form.amount === "" ? undefined : Number(form.amount),
        priceUsd: form.priceUsd === "" ? null : Number(form.priceUsd),
        valueUsd: form.valueUsd === "" ? null : Number(form.valueUsd),
        notes: form.notes === "" ? null : form.notes
      };
      const init: RequestInit = {
        method: editingId ? "PATCH" : "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(editingId ? { id: editingId, ...payload } : payload)
      };
      await fetchJson("/api/exchanges/manual", init);
      resetForm();
      setMessage(editingId ? "Manual entry updated." : "Manual entry saved.");
      await refresh();
    } catch (saveError) {
      setMessage(readError(saveError));
    } finally {
      setBusy(false);
    }
  }

  async function toggleEnabled(holding: ManualHoldingRecord) {
    setBusy(true);
    setMessage("");
    try {
      await fetchJson("/api/exchanges/manual", {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ id: holding.id, enabled: !holding.enabled })
      });
      await refresh();
    } catch (toggleError) {
      setMessage(readError(toggleError));
    } finally {
      setBusy(false);
    }
  }

  async function remove(holding: ManualHoldingRecord) {
    if (!window.confirm(`Remove manual entry "${holding.label} · ${holding.symbol}"?`)) return;
    setBusy(true);
    setMessage("");
    try {
      await fetchJson(`/api/exchanges/manual?id=${encodeURIComponent(holding.id)}`, { method: "DELETE" });
      if (editingId === holding.id) resetForm();
      await refresh();
    } catch (removeError) {
      setMessage(readError(removeError));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="aa-manual-section">
      <div className="aa-section-head">
        <span className="aa-section-title">Manual exchange entries</span>
        <span className="aa-section-meta">
          {enabledCount} active · {disabledCount} disabled · {money.format(totalUsd)}
        </span>
      </div>
      <div className="aa-manual-banner">
        <Pencil size={16} />
        <span>
          Use this when you don't want to share API keys. Values are entered by hand and never refresh
          automatically — update them when you want a fresh number. No secrets are accepted here.
        </span>
      </div>
      <div className="aa-manual-grid">
        <div className="aa-manual-form">
          <span className="aa-section-title">{editingId ? "Edit entry" : "Add entry"}</span>
          <select
            value={form.provider}
            onChange={(event) => setForm({ ...form, provider: event.target.value as ManualProvider })}
          >
            {providers.map((provider) => (
              <option key={provider.id} value={provider.id}>{provider.label}</option>
            ))}
          </select>
          {form.provider === "custom" && (
            <input
              value={form.customVenue}
              onChange={(event) => setForm({ ...form, customVenue: event.target.value })}
              placeholder="Custom venue (e.g. OTC desk)"
              maxLength={64}
            />
          )}
          <input
            value={form.label}
            onChange={(event) => setForm({ ...form, label: event.target.value })}
            placeholder="Label, e.g. Kraken cold spot"
            maxLength={64}
          />
          <div className="aa-manual-row">
            <input
              value={form.symbol}
              onChange={(event) => setForm({ ...form, symbol: event.target.value.toUpperCase() })}
              placeholder="Symbol, e.g. BTC"
              maxLength={16}
            />
            <input
              value={form.name}
              onChange={(event) => setForm({ ...form, name: event.target.value })}
              placeholder="Name (optional)"
              maxLength={80}
            />
          </div>
          <div className="aa-manual-row">
            <input
              value={form.amount}
              onChange={(event) => setForm({ ...form, amount: event.target.value })}
              placeholder="Amount"
              inputMode="decimal"
            />
            <input
              value={form.priceUsd}
              onChange={(event) => setForm({ ...form, priceUsd: event.target.value })}
              placeholder="Price USD (optional)"
              inputMode="decimal"
            />
            <input
              value={form.valueUsd}
              onChange={(event) => setForm({ ...form, valueUsd: event.target.value })}
              placeholder="Total value USD"
              inputMode="decimal"
            />
          </div>
          <input
            value={form.notes}
            onChange={(event) => setForm({ ...form, notes: event.target.value })}
            placeholder="Notes (optional)"
            maxLength={240}
          />
          <small className="aa-manual-hint">
            Provide either a price per unit or the total value in USD. Whichever you fill is used to compute the other.
          </small>
          <div className="aa-form-actions">
            <button className="aa-btn primary" type="button" onClick={submit} disabled={busy}>
              {busy ? <Loader2 className="spin" size={15} /> : <Check size={15} />} {editingId ? "Save changes" : "Add entry"}
            </button>
            {editingId && (
              <button className="aa-btn ghost" type="button" onClick={resetForm} disabled={busy}>
                Cancel
              </button>
            )}
          </div>
          {message && <p className="aa-form-message">{message}</p>}
        </div>
        <div className="aa-manual-list">
          <span className="aa-section-title">Saved entries</span>
          {holdings.length === 0 ? (
            <EmptyState title="No manual entries yet" sub="Add one to include CEX or OTC balances without an API key." />
          ) : (
            holdings.map((holding) => (
              <article className={`aa-manual-card ${holding.enabled ? "" : "disabled"}`} key={holding.id}>
                <div>
                  <strong>{holding.label}</strong>
                  <span>{holding.providerLabel} · {holding.symbol}</span>
                </div>
                <div>
                  <span>{formatAmount(holding.amount)} {holding.symbol}</span>
                  <strong>{money.format(holding.valueUsd)}</strong>
                </div>
                {holding.notes && <em>{holding.notes}</em>}
                <small>Updated {relativeTime(holding.generatedAt)} · manual entry</small>
                <div className="aa-manual-actions">
                  <button type="button" onClick={() => startEdit(holding)} disabled={busy}>
                    <Pencil size={13} /> Edit
                  </button>
                  <button type="button" onClick={() => toggleEnabled(holding)} disabled={busy}>
                    {holding.enabled ? <EyeOff size={13} /> : <Eye size={13} />} {holding.enabled ? "Disable" : "Enable"}
                  </button>
                  <button type="button" className="danger" onClick={() => remove(holding)} disabled={busy}>
                    <Trash2 size={13} /> Remove
                  </button>
                </div>
              </article>
            ))
          )}
        </div>
      </div>
    </section>
  );
}

function SnapshotHistorySection({
  history,
  historyLoaded,
  scanning,
  totalDelta,
  totalDeltaPercent
}: {
  history: ScanHistoryEntry[];
  historyLoaded: boolean;
  scanning: boolean;
  totalDelta: number;
  totalDeltaPercent: number | undefined;
}) {
  const showSkeleton = !historyLoaded || (scanning && history.length === 0);

  return (
    <section className="aa-snapshot-history">
      <div className="aa-section-head flush">
        <span className="aa-section-title">Snapshot history</span>
        <span className="aa-section-meta">
          {showSkeleton ? "Loading..." : history.length === 0 ? "No snapshots yet" : `${history.length} run${history.length === 1 ? "" : "s"}`}
        </span>
      </div>
      {showSkeleton ? (
        <div className="aa-history-skeleton" aria-hidden="true">
          <div className="aa-history-skeleton-trend" />
          <div className="aa-history-skeleton-rows">
            {Array.from({ length: 3 }).map((_, index) => <span key={index} />)}
          </div>
        </div>
      ) : history.length === 0 ? (
        <EmptyState title="No snapshots yet" sub="Each scan saves a snapshot here. Run a scan from Portfolio or above to start the timeline." />
      ) : (
        <>
          <SnapshotTrend history={history} totalDelta={totalDelta} totalDeltaPercent={totalDeltaPercent} />
          <SnapshotHistoryList history={history} />
        </>
      )}
    </section>
  );
}

type ManualHoldingForm = {
  label: string;
  provider: ManualProvider;
  customVenue: string;
  symbol: string;
  name: string;
  amount: string;
  priceUsd: string;
  valueUsd: string;
  notes: string;
};

function makeBlankManualForm(providers: ManualProviderOption[]): ManualHoldingForm {
  return {
    label: "",
    provider: (providers[0]?.id as ManualProvider) ?? "binance",
    customVenue: "",
    symbol: "",
    name: "",
    amount: "",
    priceUsd: "",
    valueUsd: "",
    notes: ""
  };
}

function SnapshotTrend({
  history,
  totalDelta,
  totalDeltaPercent
}: {
  history: ScanHistoryEntry[];
  totalDelta: number;
  totalDeltaPercent: number | undefined;
}) {
  const money = useMoney();
  const chronological = useMemo(() => history.slice().reverse(), [history]);
  const max = chronological.reduce((peak, entry) => Math.max(peak, entry.totalUsd), 0);
  const latest = history[0];
  const showBars = chronological.length > 1;
  const deltaClass = totalDelta > 0 ? "gain" : totalDelta < 0 ? "loss" : "";

  return (
    <div className="aa-trend">
      <div className="aa-trend-summary">
        <span className="aa-label">Latest snapshot value</span>
        <strong>{latest ? money.format(latest.totalUsd) : "—"}</strong>
        {showBars && (
          <small className={deltaClass}>
            {totalDelta >= 0 ? "+" : ""}{money.format(totalDelta)}
            {typeof totalDeltaPercent === "number" && ` · ${percent(totalDeltaPercent)}`} vs previous
          </small>
        )}
        {!showBars && <small>Take another snapshot to draw a trend.</small>}
      </div>
      {showBars && (
        <div className="aa-trend-bars" role="img" aria-label="Snapshot total value trend (oldest to newest)">
          {chronological.map((entry) => {
            const heightPct = max > 0 ? Math.max(4, (entry.totalUsd / max) * 100) : 4;
            return (
              <span key={entry.id} title={`${dateOnly(entry.generatedAt)} · ${money.format(entry.totalUsd)}`}>
                <i style={{ height: `${heightPct}%` }} />
              </span>
            );
          })}
        </div>
      )}
    </div>
  );
}

function SnapshotHistoryList({ history }: { history: ScanHistoryEntry[] }) {
  const money = useMoney();
  return (
    <ol className="aa-history-list">
      {history.map((entry) => (
        <li key={entry.id} className="aa-history-card">
          <div className="aa-history-head">
            <strong>{money.format(entry.totalUsd)}</strong>
            <span>{relativeTime(entry.generatedAt)}</span>
          </div>
          <small className="aa-history-meta">
            {entry.assetCount} holdings · {entry.chainCount} chain{entry.chainCount === 1 ? "" : "s"} · {entry.inputCount} input{entry.inputCount === 1 ? "" : "s"} · {entry.sourceCount} source{entry.sourceCount === 1 ? "" : "s"}
            {entry.warningCount > 0 && <em> · {entry.warningCount} warning{entry.warningCount === 1 ? "" : "s"}</em>}
          </small>
          {entry.topChains.length > 0 && (
            <ul className="aa-history-chains">
              {entry.topChains.map((chain) => (
                <li key={chain.name}>
                  <span>{chain.name}</span>
                  <em>{money.format(chain.valueUsd)}</em>
                </li>
              ))}
            </ul>
          )}
          <span className="aa-history-stamp">{new Date(entry.generatedAt).toLocaleString()}</span>
        </li>
      ))}
    </ol>
  );
}

function ExportPage(props: AppContext) {
  const money = useMoney();
  const scan = props.scan;
  const csv = assetsToCsv(scan?.assets ?? []);
  const json = scan ? scanToJson(scan) : "{}";
  const totalUsd = sumValues(scan?.assets ?? []);
  const csvCopy = money.effectiveCurrency === "USD"
    ? "Spreadsheet-friendly. One row per holding with source, chain, amount, price and USD value."
    : `Spreadsheet-friendly. Values stay USD-faithful in the file even when the app shows ${money.effectiveCurrency}.`;

  return (
    <>
      <PageHead
        compact
        section="Export"
        title="Take it elsewhere"
        lede="A snapshot of your portfolio in plain CSV or structured JSON. Public data only; the export keeps stored USD values."
        right={<HeadStats items={[["Last snapshot", scan ? relativeTime(scan.generatedAt) : "Never"], [`Snapshot total (${money.effectiveCurrency})`, money.format(totalUsd)]]} />}
        actions={<>
          <button className="aa-btn primary" type="button" onClick={() => downloadText("csv", csv, scan)}>Download .csv</button>
          <button className="aa-btn ghost dark" type="button" onClick={() => downloadText("json", json, scan)}>Download .json</button>
        </>}
      />
      <section className="aa-export-grid">
        <ExportCard title="CSV" copy={csvCopy} text={csv} fileType="csv" scan={scan} />
        <ExportCard title="JSON" copy="Structured snapshot for tooling. Includes wallets, exchange snapshots, holdings and timestamp." text={json} fileType="json" scan={scan} />
      </section>
    </>
  );
}

function SettingsPage(props: AppContext) {
  const { prefs, setPrefs, customTokens, tokenChains, refresh } = props;
  return (
    <>
      <PageHead
        compact
        section="Settings"
        title="Preferences"
        lede="Display preferences and read-only behavior. Settings persist in this local SQLite app instance."
      />
      <div className="aa-settings">
        <SettingBlock title="Appearance" copy="Paper or ink, comfortable or compact, mixed type or mono throughout.">
          <SettingRow label="Dark mode" desc="Inverted ink for late-night scans"><Toggle on={prefs.darkMode} onClick={() => setPrefs({ darkMode: !prefs.darkMode })} /></SettingRow>
          <SettingRow label="Density" desc="Row height and padding"><Segment value={prefs.density} values={["compact", "comfy"]} onChange={(density) => setPrefs({ density: density as PreferenceRecord["density"] })} /></SettingRow>
          <SettingRow label="Mono everywhere" desc="Use mono for body text too"><Toggle on={prefs.mono} onClick={() => setPrefs({ mono: !prefs.mono })} /></SettingRow>
        </SettingBlock>
        <SettingBlock title="Display" copy="Dust and currency affect what you see; stored holdings stay untouched.">
          <SettingRow label="Hide dust" desc="Hide holdings under threshold"><Toggle on={prefs.hideDust} onClick={() => setPrefs({ hideDust: !prefs.hideDust })} /></SettingRow>
          <SettingRow label="Dust threshold" desc="USD value below which holding counts as dust"><Segment value={String(prefs.dustThreshold)} values={["1", "5", "25", "100"]} onChange={(value) => setPrefs({ dustThreshold: Number(value) })} prefix="$" /></SettingRow>
          <SettingRow label="Display currency" desc="Converts displayed totals from USD using a live CoinGecko quote; falls back to USD if unavailable"><Segment value={prefs.currency} values={["USD", "EUR", "GBP", "TRY"]} onChange={(currency) => setPrefs({ currency })} /></SettingRow>
        </SettingBlock>
        <SettingBlock
          title="Token allowlist"
          copy="Add ERC-20 tokens to scan in addition to the built-in registry. Disabled tokens are kept in the list but skipped during scans."
        >
          <TokenAllowlistManager tokens={customTokens} chains={tokenChains} onChange={refresh} />
        </SettingBlock>
        <SettingBlock title="Data" copy="How often Address Atlas re-checks public endpoints.">
          <SettingRow label="Auto-refresh" desc="Re-scans saved wallets every five minutes; exchanges are included only when a vault passphrase is set this session"><Toggle on={prefs.autoRefresh} onClick={() => setPrefs({ autoRefresh: !prefs.autoRefresh })} /></SettingRow>
          <SettingRow label="Cache" desc="Last successful scan lives in SQLite"><button className="aa-btn ghost" type="button" onClick={() => window.location.reload()}>Reload app</button></SettingRow>
        </SettingBlock>
        <SettingBlock title="Privacy" copy="Read-only by design. Nothing here can sign or send.">
          {TRUST_POINTS.map((point) => <SettingRow key={point} label={point} desc="Enforced by UI and API validation"><span className="aa-enforced">● enforced</span></SettingRow>)}
        </SettingBlock>
      </div>
    </>
  );
}

function TokenAllowlistManager({
  tokens,
  chains,
  onChange
}: {
  tokens: CustomTokenRecord[];
  chains: TokenChainOption[];
  onChange: () => Promise<void>;
}) {
  const [form, setForm] = useState(EMPTY_TOKEN_FORM);
  const [submitting, setSubmitting] = useState(false);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [message, setMessage] = useState("");
  const [errorMessage, setErrorMessage] = useState("");

  const chainOptions = chains.length > 0 ? chains : [{ id: "ethereum", name: "Ethereum", family: "evm" }];

  async function addToken() {
    setSubmitting(true);
    setMessage("");
    setErrorMessage("");
    try {
      await fetchJson("/api/tokens", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          chainKind: "evm",
          chainId: form.chainId,
          address: form.address.trim(),
          symbol: form.symbol.trim(),
          name: form.name.trim(),
          decimals: Number(form.decimals),
          coinGeckoId: form.coinGeckoId.trim()
        })
      });
      setForm({ ...EMPTY_TOKEN_FORM, chainId: form.chainId });
      setMessage(`Added ${form.symbol.trim()}.`);
      await onChange();
    } catch (addError) {
      setErrorMessage(readError(addError));
    } finally {
      setSubmitting(false);
    }
  }

  async function toggleEnabled(token: CustomTokenRecord) {
    setBusyId(token.id);
    setErrorMessage("");
    try {
      await fetchJson("/api/tokens", {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ id: token.id, enabled: !token.enabled })
      });
      await onChange();
    } catch (toggleError) {
      setErrorMessage(readError(toggleError));
    } finally {
      setBusyId(null);
    }
  }

  async function removeToken(token: CustomTokenRecord) {
    if (!window.confirm(`Remove ${token.symbol} from the allowlist?`)) return;
    setBusyId(token.id);
    setErrorMessage("");
    try {
      await fetchJson(`/api/tokens?id=${encodeURIComponent(token.id)}`, { method: "DELETE" });
      await onChange();
    } catch (deleteError) {
      setErrorMessage(readError(deleteError));
    } finally {
      setBusyId(null);
    }
  }

  return (
    <div className="aa-token-allowlist">
      <div className="aa-token-form">
        <div className="aa-token-form-grid">
          <label>
            <span>Chain</span>
            <select value={form.chainId} onChange={(event) => setForm({ ...form, chainId: event.target.value })}>
              {chainOptions.map((chain) => (
                <option key={chain.id} value={chain.id}>{chain.name}</option>
              ))}
            </select>
          </label>
          <label>
            <span>Symbol</span>
            <input value={form.symbol} onChange={(event) => setForm({ ...form, symbol: event.target.value })} placeholder="e.g. AAVE" />
          </label>
          <label>
            <span>Name</span>
            <input value={form.name} onChange={(event) => setForm({ ...form, name: event.target.value })} placeholder="e.g. Aave" />
          </label>
          <label className="span-2">
            <span>Contract address</span>
            <input value={form.address} onChange={(event) => setForm({ ...form, address: event.target.value })} placeholder="0x..." spellCheck={false} />
          </label>
          <label>
            <span>Decimals</span>
            <input value={form.decimals} onChange={(event) => setForm({ ...form, decimals: event.target.value })} placeholder="18" inputMode="numeric" />
          </label>
          <label>
            <span>CoinGecko id</span>
            <input value={form.coinGeckoId} onChange={(event) => setForm({ ...form, coinGeckoId: event.target.value })} placeholder="aave" spellCheck={false} />
          </label>
        </div>
        <div className="aa-form-actions">
          <button className="aa-btn primary" type="button" onClick={addToken} disabled={submitting}>
            {submitting ? <Loader2 className="spin" size={15} /> : <Plus size={15} />} Add token
          </button>
          {message && <span className="aa-token-message ok">{message}</span>}
          {errorMessage && <span className="aa-token-message err">{errorMessage}</span>}
        </div>
      </div>
      {tokens.length === 0 ? (
        <p className="aa-token-empty">No custom tokens yet. Built-in stablecoins still scan as usual.</p>
      ) : (
        <ul className="aa-token-list">
          {tokens.map((token) => {
            const chainLabel = chains.find((chain) => chain.id === token.chainId)?.name ?? token.chainId;
            return (
              <li key={token.id} className={`aa-token-row ${token.enabled ? "" : "off"}`}>
                <div className="aa-token-id">
                  <strong>{token.symbol}</strong>
                  <span>{token.name}</span>
                </div>
                <div className="aa-token-meta">
                  <span className="chain">{chainLabel}</span>
                  <code>{token.address}</code>
                  <small>{token.decimals} decimals · cg:{token.coinGeckoId}</small>
                </div>
                <div className="aa-token-actions">
                  <Toggle on={token.enabled} onClick={() => toggleEnabled(token)} />
                  <button
                    type="button"
                    className="aa-token-danger"
                    onClick={() => removeToken(token)}
                    disabled={busyId === token.id}
                    aria-label={`Remove ${token.symbol}`}
                  >
                    <Trash2 size={14} />
                  </button>
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}

type AppContext = {
  rawText: string;
  setRawText: (value: string) => void;
  wallets: WalletRecord[];
  scan: ScanResponse | null;
  prefs: PreferenceRecord;
  setPrefs: (value: Partial<PreferenceRecord>) => Promise<void>;
  connections: ExchangeConnection[];
  providers: ExchangeProviderOption[];
  manualHoldings: ManualHoldingRecord[];
  manualProviders: ManualProviderOption[];
  vaultReady: boolean;
  vaultPassphrase: string;
  setVaultPassphrase: (value: string) => void;
  customTokens: CustomTokenRecord[];
  tokenChains: TokenChainOption[];
  history: ScanHistoryEntry[];
  historyLoaded: boolean;
  loading: boolean;
  scanning: boolean;
  notice: string;
  error: string;
  refresh: () => Promise<void>;
  runScan: (options?: { savedOnly?: boolean; includeExchanges?: boolean; silent?: boolean }) => Promise<void>;
};

function PasteBox({
  rawText,
  setRawText,
  scanning,
  onScan,
  onLoadSample
}: {
  rawText: string;
  setRawText: (value: string) => void;
  scanning: boolean;
  onScan: () => void;
  onLoadSample: () => void;
}) {
  const lines = rawText.trim() ? rawText.trim().split(/\n+/g).filter(Boolean).length : 0;
  return (
    <div>
      <div className="aa-section-head flush">
        <span className="aa-section-title">Address intake</span>
        <span className="aa-section-meta">{lines} lines · paste one per line</span>
      </div>
      <div className="aa-pastebox">
        <textarea
          value={rawText}
          onChange={(event) => setRawText(event.target.value)}
          placeholder="bc1q...  ·  0x...  ·  cosmos1...  ·  Solana base58..."
          spellCheck={false}
        />
        <div className="aa-paste-actions">
          <button className="aa-scan-button" type="button" onClick={onScan} disabled={scanning || !rawText.trim()}>
            {scanning ? <Loader2 className="spin" size={16} /> : <Database size={16} />}
            {scanning ? "Scanning..." : "Scan addresses"}
          </button>
          <button className="aa-load-button" type="button" onClick={onLoadSample}>Load sample wallets</button>
        </div>
      </div>
    </div>
  );
}

function AssetTable({ assets, wallets, hideControls }: { assets: TrackedAsset[]; wallets: WalletRecord[]; hideControls?: boolean }) {
  const money = useMoney();
  const [query, setQuery] = useState("");
  const [sortKey, setSortKey] = useState<"name" | "chain" | "amount" | "change" | "value">("value");
  const [sortDir, setSortDir] = useState<"asc" | "desc">("desc");
  const walletByAddress = useMemo(() => new Map(wallets.map((wallet) => [wallet.address.toLowerCase(), wallet])), [wallets]);
  const filtered = useMemo(() => {
    const q = query.toLowerCase();
    return assets
      .filter((asset) => !q || [asset.symbol, asset.name, asset.chainName, asset.walletLabel, asset.address].some((value) => value?.toLowerCase().includes(q)))
      .slice()
      .sort((a, b) => compareAsset(a, b, sortKey, sortDir));
  }, [assets, query, sortKey, sortDir]);

  function flip(key: typeof sortKey) {
    if (sortKey === key) setSortDir(sortDir === "asc" ? "desc" : "asc");
    else {
      setSortKey(key);
      setSortDir("desc");
    }
  }

  if (assets.length === 0) return <EmptyState title="No balances yet" sub="Run a scan to build the holdings index." />;

  return (
    <div className="aa-table-wrap">
      {!hideControls && <Toolbar query={query} setQuery={setQuery} meta={`${filtered.length} of ${assets.length}`} placeholder="Filter by symbol, name, chain..." />}
      <div className="aa-table-scroll">
        <table className="aa-table">
          <thead>
            <tr>
              <th onClick={() => flip("name")}>Asset</th>
              <th onClick={() => flip("chain")}>Chain</th>
              <th>Wallet</th>
              <th className="right" onClick={() => flip("amount")}>Amount</th>
              <th className="right" onClick={() => flip("change")}>24h</th>
              <th className="right" onClick={() => flip("value")}>{money.effectiveCurrency} value</th>
              <th className="right" />
            </tr>
          </thead>
          <tbody>
            {filtered.map((asset) => {
              const wallet = walletByAddress.get(asset.address.toLowerCase());
              return (
                <tr key={asset.id}>
                  <td><AssetIdentity asset={asset} /></td>
                  <td>{asset.chainName}</td>
                  <td><span className="aa-addr-cell">{asset.walletLabel || wallet?.label || shortAddress(asset.address)}</span></td>
                  <td className="right mono">{formatAmount(asset.amount)} {asset.symbol}</td>
                  <td className={`right ${asset.change24h && asset.change24h < 0 ? "loss" : "gain"}`}>{percent(asset.change24h)}</td>
                  <td className="right strong">{money.format(asset.valueUsd)}</td>
                  <td className="right">{asset.explorerUrl && <a className="aa-text-link" href={asset.explorerUrl} target="_blank" rel="noreferrer">view</a>}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <div className="aa-asset-cards">
        {filtered.map((asset) => {
          const wallet = walletByAddress.get(asset.address.toLowerCase());
          return (
            <article className="aa-asset-card" key={asset.id}>
              <AssetIdentity asset={asset} />
              <strong>{money.format(asset.valueUsd)}</strong>
              <small>{asset.chainName} · {asset.walletLabel || wallet?.label || shortAddress(asset.address)}</small>
              <span>{formatAmount(asset.amount)} {asset.symbol} · {percent(asset.change24h)}</span>
            </article>
          );
        })}
      </div>
    </div>
  );
}

function AssetIdentity({ asset }: { asset: TrackedAsset }) {
  return (
    <div className="aa-asset-id">
      <span>{asset.symbol.slice(0, 3)}</span>
      <div>
        <strong>{asset.name}</strong>
        <small>{asset.symbol}</small>
      </div>
    </div>
  );
}

function Toolbar({ query, setQuery, meta, placeholder }: { query: string; setQuery: (value: string) => void; meta: string; placeholder: string }) {
  return (
    <div className="aa-toolbar">
      <label>
        <Search size={14} />
        <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder={placeholder} />
      </label>
      <span>{meta}</span>
    </div>
  );
}

function AllocationPanel({ allocation, total }: { allocation: { name: string; value: number }[]; total: number }) {
  const money = useMoney();
  return (
    <aside className="aa-allocation">
      <span className="aa-section-title">Chain allocation</span>
      <div className="aa-donut" style={{ background: donutGradient(allocation, total) }}>
        <span>{allocation.length}</span>
        <small>chains</small>
      </div>
      <div className="aa-chain-list">
        {allocation.map((item) => (
          <div key={item.name}>
            <span>{item.name}</span>
            <strong>{total ? ((item.value / total) * 100).toFixed(1) : "0.0"}%</strong>
            <em>{money.format(item.value)}</em>
          </div>
        ))}
      </div>
    </aside>
  );
}

function ExportCard({ title, copy, text, fileType, scan }: { title: string; copy: string; text: string; fileType: "csv" | "json"; scan: ScanResponse | null }) {
  return (
    <article className="aa-export-card">
      <h2>{title}</h2>
      <p>{copy}</p>
      <pre>{text.split("\n").slice(0, fileType === "json" ? 16 : 10).join("\n")}</pre>
      <div className="aa-form-actions">
        <button className="aa-btn primary" type="button" onClick={() => downloadText(fileType, text, scan)}><Download size={15} /> Download .{fileType}</button>
        <button className="aa-btn ghost" type="button" onClick={() => copyText(text)}><Copy size={15} /> Copy</button>
      </div>
    </article>
  );
}

function SettingBlock({ title, copy, children }: { title: string; copy: string; children: ReactNode }) {
  return (
    <section className="aa-setting-block">
      <div>
        <h2>{title}</h2>
        <p>{copy}</p>
      </div>
      <div>{children}</div>
    </section>
  );
}

function SettingRow({ label, desc, children }: { label: string; desc: string; children: ReactNode }) {
  return (
    <div className="aa-setting-row">
      <span>
        <strong>{label}</strong>
        <small>{desc}</small>
      </span>
      {children}
    </div>
  );
}

function Segment({ value, values, onChange, prefix = "" }: { value: string; values: string[]; onChange: (value: string) => void; prefix?: string }) {
  return (
    <div className="aa-segment">
      {values.map((item) => (
        <button key={item} className={value === item ? "on" : ""} type="button" onClick={() => onChange(item)}>{prefix}{item}</button>
      ))}
    </div>
  );
}

function Toggle({ on, onClick }: { on: boolean; onClick: () => void }) {
  return <button className={`aa-toggle ${on ? "on" : ""}`} type="button" role="switch" aria-checked={on} onClick={onClick}><i /></button>;
}

function StatusLine({ notice, error, scanning }: { notice: string; error: string; scanning: boolean }) {
  if (scanning) return <div className="aa-state"><Loader2 className="spin" size={15} /> Scanning public endpoints...</div>;
  if (error) return <div className="aa-state error">{error}</div>;
  if (notice) return <div className="aa-state success">{notice}</div>;
  return null;
}

function EmptyState({ title, sub }: { title: string; sub: string }) {
  return (
    <div className="aa-empty">
      <Wallet size={28} />
      <strong>{title}</strong>
      <span>{sub}</span>
    </div>
  );
}

function Metric({ label, value }: { label: string; value: number }) {
  return (
    <div className="aa-metric">
      <span>{label}</span>
      <strong>{String(value).padStart(2, "0")}</strong>
    </div>
  );
}

function HeadStats({ items }: { items: [string, ReactNode][] }) {
  return (
    <>
      {items.map(([label, value]) => (
        <span key={label}>
          <small>{label}</small>
          <strong>{value}</strong>
        </span>
      ))}
    </>
  );
}

function Footer() {
  return (
    <footer className="aa-footer">
      <div>{TRUST_POINTS.map((point) => <span key={point}>● {point}</span>)}</div>
      <span>Address Atlas · local-first · public data only</span>
    </footer>
  );
}

async function fetchJson<T>(url: string, init?: RequestInit): Promise<T> {
  const response = await fetch(url, init);
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(body.details || body.error || "Request failed.");
  }
  return body as T;
}

function filteredAssets(assets: TrackedAsset[], prefs: PreferenceRecord) {
  return assets
    .filter((asset) => !prefs.hideDust || asset.valueUsd >= prefs.dustThreshold)
    .slice()
    .sort((a, b) => b.valueUsd - a.valueUsd);
}

function allocationByChain(assets: TrackedAsset[]) {
  const totals = new Map<string, number>();
  assets.forEach((asset) => {
    totals.set(asset.chainName, (totals.get(asset.chainName) ?? 0) + asset.valueUsd);
  });
  return Array.from(totals.entries()).map(([name, value]) => ({ name, value })).sort((a, b) => b.value - a.value);
}

function donutGradient(allocation: { value: number }[], total: number) {
  if (!allocation.length || total <= 0) return "conic-gradient(var(--paper-3) 0 100%)";
  const colors = ["oklch(42% 0.07 40)", "oklch(42% 0.08 145)", "oklch(45% 0.08 250)", "oklch(46% 0.08 310)", "oklch(48% 0.10 25)"];
  let cursor = 0;
  const stops = allocation.map((item, index) => {
    const start = cursor;
    cursor += (item.value / total) * 100;
    return `${colors[index % colors.length]} ${start}% ${cursor}%`;
  });
  return `conic-gradient(${stops.join(", ")})`;
}

function compareAsset(a: TrackedAsset, b: TrackedAsset, key: "name" | "chain" | "amount" | "change" | "value", dir: "asc" | "desc") {
  let result = 0;
  if (key === "name") result = a.name.localeCompare(b.name);
  if (key === "chain") result = a.chainName.localeCompare(b.chainName);
  if (key === "amount") result = a.amount - b.amount;
  if (key === "change") result = (a.change24h ?? 0) - (b.change24h ?? 0);
  if (key === "value") result = a.valueUsd - b.valueUsd;
  return dir === "asc" ? result : -result;
}

function totalsByWallet(assets: TrackedAsset[], wallets: WalletRecord[]) {
  const walletByAddress = new Map(wallets.map((wallet) => [wallet.address.toLowerCase(), wallet.id]));
  const totals = new Map<string, number>();
  assets.forEach((asset) => {
    const walletId = walletByAddress.get(asset.address.toLowerCase());
    if (walletId) totals.set(walletId, (totals.get(walletId) ?? 0) + asset.valueUsd);
  });
  return totals;
}

function sumValues(assets: TrackedAsset[]) {
  return assets.reduce((sum, asset) => sum + asset.valueUsd, 0);
}

function formatAmount(value: number) {
  if (value >= 1000) return value.toLocaleString(undefined, { maximumFractionDigits: 2 });
  if (value >= 1) return value.toLocaleString(undefined, { maximumFractionDigits: 5 });
  return value.toLocaleString(undefined, { maximumFractionDigits: 8 });
}

function shortAddress(value: string) {
  if (!value) return "";
  if (value.length <= 18) return value;
  return `${value.slice(0, 8)}...${value.slice(-6)}`;
}

function relativeTime(value: string) {
  const diff = Date.now() - new Date(value).getTime();
  if (!Number.isFinite(diff)) return "unknown";
  const minutes = Math.max(0, Math.round(diff / 60000));
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} hr ago`;
  return dateOnly(value);
}

function dateOnly(value: string) {
  return new Date(value).toISOString().slice(0, 10);
}

function explorerForWallet(wallet: WalletRecord) {
  if (wallet.chainKind === "bitcoin") return `https://blockstream.info/address/${wallet.address}`;
  if (wallet.chainKind === "solana") return `https://solscan.io/account/${wallet.address}`;
  if (wallet.chainKind === "cosmos") return `https://www.mintscan.io/cosmos/address/${wallet.address}`;
  return `https://etherscan.io/address/${wallet.address}`;
}

function downloadCsv(assets: TrackedAsset[]) {
  downloadFile("address-atlas-filtered.csv", "text/csv;charset=utf-8", assetsToCsv(assets));
}

function downloadText(fileType: "csv" | "json", text: string, scan: ScanResponse | null) {
  const stamp = scan?.generatedAt ? timestampForFile(scan.generatedAt) : "empty";
  downloadFile(`address-atlas-${stamp}.${fileType}`, fileType === "csv" ? "text/csv;charset=utf-8" : "application/json", text);
}

function downloadFile(filename: string, type: string, content: string) {
  const blob = new Blob([content], { type });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

async function copyText(text: string) {
  await navigator.clipboard.writeText(text);
}

function readError(error: unknown) {
  return error instanceof Error ? error.message : "Something went wrong.";
}
