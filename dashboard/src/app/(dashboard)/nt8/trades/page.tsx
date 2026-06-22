'use client';

import { useEffect, useState, useCallback } from 'react';

interface Trade {
  id: string;
  account_name: string;
  instrument: string;
  strategy_name: string | null;
  direction: string;
  entry_ct: string;
  exit_ct: string | null;
  entry_price: number;
  exit_price: number | null;
  qty: number;
  pnl_dollars: number | null;
  exit_signal: string | null;
  commission: number | null;
  tp_ticks: number | null;
  sl_ticks: number | null;
  orb_range_ticks: number | null;
  vix_regime: string | null;
  orb_high: number | null;
  orb_low: number | null;
  effective_direction: string | null;
  exit_mode: string | null;
  sod_balance: number | null;
}

interface Summary {
  account_name: string;
  instrument: string;
  completed: number;
  open: number;
  total_pnl: string | null;
  winners: number;
  losers: number;
}

function fmt(v: number | null, decimals = 2): string {
  if (v === null || v === undefined) return '—';
  return v.toFixed(decimals);
}

function fmtPnl(v: number | null): React.ReactNode {
  if (v === null || v === undefined) return <span className="text-muted-foreground">—</span>;
  const cls = v > 0 ? 'text-green-500' : v < 0 ? 'text-red-500' : 'text-muted-foreground';
  return <span className={cls}>{v > 0 ? '+' : ''}{v.toFixed(2)}</span>;
}

function fmtTime(iso: string | null): string {
  if (!iso) return '—';
  const d = new Date(iso);
  return d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: true });
}

export default function TradesPage() {
  const [trades, setTrades] = useState<Trade[]>([]);
  const [summary, setSummary] = useState<Summary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [days, setDays] = useState(1);
  const [account, setAccount] = useState('');
  const [showOpen, setShowOpen] = useState(false);

  const loadTrades = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const params = new URLSearchParams();
      if (showOpen) {
        params.set('open', 'true');
      } else {
        params.set('days', String(days));
      }
      if (account) params.set('account', account);

      const res = await fetch(`/api/nt8/trades?${params}`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      setTrades(data.trades ?? []);
      setSummary(data.summary ?? []);
    } catch (e) {
      setError(String(e));
    } finally {
      setLoading(false);
    }
  }, [days, account, showOpen]);

  useEffect(() => { loadTrades(); }, [loadTrades]);

  const totalPnl = summary.reduce((sum, s) => sum + parseFloat(s.total_pnl ?? '0'), 0);
  const totalTrades = summary.reduce((sum, s) => sum + Number(s.completed), 0);
  const totalWinners = summary.reduce((sum, s) => sum + Number(s.winners), 0);
  const winRate = totalTrades > 0 ? ((totalWinners / totalTrades) * 100).toFixed(0) : '—';

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold">NT8 Trade Log</h1>
        <button
          onClick={loadTrades}
          className="text-sm text-muted-foreground hover:text-foreground border rounded px-3 py-1"
        >
          Refresh
        </button>
      </div>

      {/* Filters */}
      <div className="flex flex-wrap gap-3 items-center">
        <label className="flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            checked={showOpen}
            onChange={e => setShowOpen(e.target.checked)}
            className="rounded"
          />
          Open positions only
        </label>
        {!showOpen && (
          <label className="flex items-center gap-2 text-sm">
            Days back:
            <select
              value={days}
              onChange={e => setDays(Number(e.target.value))}
              className="border rounded px-2 py-1 bg-background text-sm"
            >
              <option value={1}>Today</option>
              <option value={3}>3 days</option>
              <option value={7}>7 days</option>
              <option value={14}>14 days</option>
              <option value={30}>30 days</option>
            </select>
          </label>
        )}
        <label className="flex items-center gap-2 text-sm">
          Account:
          <input
            type="text"
            value={account}
            onChange={e => setAccount(e.target.value)}
            placeholder="all"
            className="border rounded px-2 py-1 bg-background text-sm w-48"
          />
        </label>
      </div>

      {/* Summary cards */}
      {!loading && summary.length > 0 && (
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          <div className="border rounded-lg p-4">
            <div className="text-xs text-muted-foreground uppercase tracking-wide">Total P&amp;L</div>
            <div className={`text-2xl font-bold mt-1 ${totalPnl > 0 ? 'text-green-500' : totalPnl < 0 ? 'text-red-500' : ''}`}>
              {totalPnl > 0 ? '+' : ''}{totalPnl.toFixed(2)}
            </div>
          </div>
          <div className="border rounded-lg p-4">
            <div className="text-xs text-muted-foreground uppercase tracking-wide">Trades</div>
            <div className="text-2xl font-bold mt-1">{totalTrades}</div>
          </div>
          <div className="border rounded-lg p-4">
            <div className="text-xs text-muted-foreground uppercase tracking-wide">Win Rate</div>
            <div className="text-2xl font-bold mt-1">{winRate}%</div>
          </div>
          <div className="border rounded-lg p-4">
            <div className="text-xs text-muted-foreground uppercase tracking-wide">Accounts</div>
            <div className="text-2xl font-bold mt-1">{summary.length}</div>
          </div>
        </div>
      )}

      {/* Per-account summary */}
      {!loading && summary.length > 1 && (
        <div className="border rounded-lg overflow-hidden">
          <div className="px-4 py-3 border-b text-sm font-medium text-muted-foreground">By Account</div>
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b bg-muted/30">
                <th className="text-left px-4 py-2">Account</th>
                <th className="text-left px-4 py-2">Instrument</th>
                <th className="text-right px-4 py-2">Trades</th>
                <th className="text-right px-4 py-2">W/L</th>
                <th className="text-right px-4 py-2">P&amp;L</th>
              </tr>
            </thead>
            <tbody>
              {summary.map((s, i) => (
                <tr key={i} className="border-b last:border-0 hover:bg-muted/20">
                  <td className="px-4 py-2 font-mono text-xs">{s.account_name}</td>
                  <td className="px-4 py-2">{s.instrument}</td>
                  <td className="px-4 py-2 text-right">{s.completed}</td>
                  <td className="px-4 py-2 text-right text-xs">
                    <span className="text-green-500">{s.winners}W</span>
                    {' / '}
                    <span className="text-red-500">{s.losers}L</span>
                  </td>
                  <td className="px-4 py-2 text-right">{fmtPnl(s.total_pnl ? parseFloat(s.total_pnl) : null)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {/* Trade table */}
      <div className="border rounded-lg overflow-hidden">
        <div className="px-4 py-3 border-b text-sm font-medium text-muted-foreground">
          {loading ? 'Loading…' : `${trades.length} trade${trades.length !== 1 ? 's' : ''}`}
        </div>

        {error && (
          <div className="px-4 py-3 text-sm text-red-500">Error: {error}</div>
        )}

        {!loading && trades.length === 0 && !error && (
          <div className="px-4 py-6 text-sm text-muted-foreground text-center">No trades found</div>
        )}

        {trades.length > 0 && (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b bg-muted/30">
                  <th className="text-left px-3 py-2">Account</th>
                  <th className="text-left px-3 py-2">Instrument</th>
                  <th className="text-left px-3 py-2">Dir</th>
                  <th className="text-right px-3 py-2">Qty</th>
                  <th className="text-right px-3 py-2">Entry CT</th>
                  <th className="text-right px-3 py-2">Exit CT</th>
                  <th className="text-right px-3 py-2">Entry $</th>
                  <th className="text-right px-3 py-2">Exit $</th>
                  <th className="text-right px-3 py-2">P&amp;L</th>
                  <th className="text-left px-3 py-2">Exit Reason</th>
                  <th className="text-right px-3 py-2">ORB Ticks</th>
                  <th className="text-left px-3 py-2">VIX</th>
                </tr>
              </thead>
              <tbody>
                {trades.map((t) => (
                  <tr key={t.id} className="border-b last:border-0 hover:bg-muted/20">
                    <td className="px-3 py-2 font-mono text-xs whitespace-nowrap">{t.account_name}</td>
                    <td className="px-3 py-2 whitespace-nowrap">{t.instrument}</td>
                    <td className="px-3 py-2">
                      <span className={t.direction === 'Long' ? 'text-green-500' : 'text-red-500'}>
                        {t.direction}
                      </span>
                    </td>
                    <td className="px-3 py-2 text-right">{t.qty}</td>
                    <td className="px-3 py-2 text-right whitespace-nowrap">{fmtTime(t.entry_ct)}</td>
                    <td className="px-3 py-2 text-right whitespace-nowrap">
                      {t.exit_ct ? fmtTime(t.exit_ct) : <span className="text-yellow-500 text-xs">OPEN</span>}
                    </td>
                    <td className="px-3 py-2 text-right">{fmt(t.entry_price, 4)}</td>
                    <td className="px-3 py-2 text-right">{t.exit_price !== null ? fmt(t.exit_price, 4) : '—'}</td>
                    <td className="px-3 py-2 text-right font-medium">{fmtPnl(t.pnl_dollars)}</td>
                    <td className="px-3 py-2 text-xs text-muted-foreground">{t.exit_signal ?? '—'}</td>
                    <td className="px-3 py-2 text-right text-xs">{t.orb_range_ticks ?? '—'}</td>
                    <td className="px-3 py-2 text-xs">{t.vix_regime ?? '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}
