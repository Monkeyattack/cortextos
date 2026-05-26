'use client';

import { useEffect, useState, useCallback } from 'react';
import { NodeStatus } from '@/components/nt8/NodeStatus';
import { StrategyTable } from '@/components/nt8/StrategyTable';
import { PositionsTable } from '@/components/nt8/PositionsTable';
import { AuditLog } from '@/components/nt8/AuditLog';
import type { NodeState, Nt8Event, StrategyInstance } from '@/components/nt8/types';

interface StreamPayload {
  nodes: NodeState[];
  events: Nt8Event[];
  updated_at: string;
}

export default function Nt8Page() {
  const [nodes, setNodes] = useState<NodeState[]>([]);
  const [events, setEvents] = useState<Nt8Event[]>([]);
  const [updatedAt, setUpdatedAt] = useState<string | null>(null);
  const [streamStatus, setStreamStatus] = useState<'connecting' | 'connected' | 'error'>('connecting');
  const [cmdError, setCmdError] = useState<string | null>(null);

  // SSE subscription
  useEffect(() => {
    const es = new EventSource('/api/nt8/stream');

    es.onopen = () => setStreamStatus('connected');

    es.onmessage = (e) => {
      try {
        const payload: StreamPayload = JSON.parse(e.data);
        setNodes(payload.nodes);
        setEvents(payload.events);
        setUpdatedAt(payload.updated_at);
      } catch {
        // Ignore malformed frames
      }
    };

    es.onerror = () => setStreamStatus('error');

    return () => es.close();
  }, []);

  const handleToggle = useCallback(async (nodeId: string, strategy: StrategyInstance) => {
    const type = strategy.status === 'Enabled' ? 'disable_strategy' : 'enable_strategy';
    setCmdError(null);

    const resp = await fetch('/api/nt8/command', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        node_id: nodeId,
        type,
        strategy_name: strategy.strategy_name,
        account: strategy.account,
      }),
    });

    if (!resp.ok) {
      const body = await resp.json().catch(() => ({}));
      setCmdError(body.error ?? `HTTP ${resp.status}`);
    }
  }, []);

  const totalStrategies = nodes.reduce((n, node) => n + node.strategies.length, 0);
  const totalPositions = nodes.reduce((n, node) => n + node.positions.length, 0);

  return (
    <div className="space-y-6 p-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold">NT8 Remote Control</h1>
          <p className="text-sm text-muted-foreground mt-1">
            {updatedAt ? `Updated ${new Date(updatedAt).toLocaleTimeString()}` : 'Connecting...'}
          </p>
        </div>
        <div className="flex items-center gap-2 text-sm">
          <span
            className={`inline-block w-2 h-2 rounded-full ${
              streamStatus === 'connected'
                ? 'bg-green-500'
                : streamStatus === 'error'
                  ? 'bg-red-500'
                  : 'bg-yellow-500 animate-pulse'
            }`}
          />
          <span className="text-muted-foreground">
            {streamStatus === 'connected' ? 'Live' : streamStatus === 'error' ? 'Disconnected' : 'Connecting'}
          </span>
        </div>
      </div>

      {/* Node status row */}
      <div className="rounded-lg border bg-card p-4">
        <h2 className="text-sm font-medium mb-3">Nodes</h2>
        <NodeStatus nodes={nodes} />
      </div>

      {/* Command error */}
      {cmdError && (
        <div className="rounded-lg border border-red-500/30 bg-red-500/5 px-4 py-3 text-sm text-red-600 dark:text-red-400">
          Command error: {cmdError}
          <button className="ml-3 underline" onClick={() => setCmdError(null)}>
            dismiss
          </button>
        </div>
      )}

      {/* Strategies */}
      <div className="rounded-lg border bg-card p-4">
        <h2 className="text-sm font-medium mb-3">
          Strategies
          {totalStrategies > 0 && (
            <span className="ml-2 text-xs text-muted-foreground">({totalStrategies})</span>
          )}
        </h2>
        <StrategyTable nodes={nodes} onToggle={handleToggle} />
      </div>

      {/* Positions */}
      <div className="rounded-lg border bg-card p-4">
        <h2 className="text-sm font-medium mb-3">
          Open Positions
          {totalPositions > 0 && (
            <span className="ml-2 text-xs text-muted-foreground">({totalPositions})</span>
          )}
        </h2>
        <PositionsTable nodes={nodes} />
      </div>

      {/* Audit log */}
      <div className="rounded-lg border bg-card p-4">
        <h2 className="text-sm font-medium mb-3">
          Audit Log
          <span className="ml-2 text-xs text-muted-foreground">(last 20)</span>
        </h2>
        <AuditLog events={events} />
      </div>
    </div>
  );
}
