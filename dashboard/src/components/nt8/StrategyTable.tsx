'use client';

import { useState } from 'react';
import type { NodeState, StrategyInstance } from './types';

interface Props {
  nodes: NodeState[];
  onToggle: (nodeId: string, strategy: StrategyInstance) => Promise<void>;
}

export function StrategyTable({ nodes, onToggle }: Props) {
  const [pending, setPending] = useState<Set<string>>(new Set());

  const handleToggle = async (nodeId: string, strategy: StrategyInstance) => {
    const key = `${nodeId}:${strategy.strategy_name}:${strategy.account}`;
    setPending((p) => new Set(p).add(key));
    try {
      await onToggle(nodeId, strategy);
    } finally {
      setPending((p) => {
        const next = new Set(p);
        next.delete(key);
        return next;
      });
    }
  };

  const allStrategies = nodes.flatMap((node) =>
    node.strategies.map((s) => ({ ...s, node_id: node.node_id })),
  );

  if (allStrategies.length === 0) {
    return (
      <div className="text-sm text-muted-foreground py-4 text-center">
        No strategies found
      </div>
    );
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b text-muted-foreground text-left">
            <th className="py-2 pr-4 font-medium">Node</th>
            <th className="py-2 pr-4 font-medium">Strategy</th>
            <th className="py-2 pr-4 font-medium">Account</th>
            <th className="py-2 pr-4 font-medium">Instrument</th>
            <th className="py-2 pr-4 font-medium">Status</th>
            <th className="py-2 font-medium">Action</th>
          </tr>
        </thead>
        <tbody>
          {allStrategies.map((s) => {
            const key = `${s.node_id}:${s.strategy_name}:${s.account}`;
            const isEnabled = s.status === 'Enabled';
            const isPending = pending.has(key);

            return (
              <tr key={key} className="border-b last:border-0 hover:bg-muted/30">
                <td className="py-2 pr-4 font-mono text-xs">{s.node_id}</td>
                <td className="py-2 pr-4 font-medium">{s.strategy_name}</td>
                <td className="py-2 pr-4 font-mono text-xs">{s.account}</td>
                <td className="py-2 pr-4">{s.instrument}</td>
                <td className="py-2 pr-4">
                  <span
                    className={`inline-flex items-center gap-1.5 text-xs font-medium rounded-full px-2 py-0.5 ${
                      s.running
                        ? 'bg-green-500/10 text-green-600 dark:text-green-400'
                        : isEnabled
                          ? 'bg-blue-500/10 text-blue-600 dark:text-blue-400'
                          : 'bg-muted text-muted-foreground'
                    }`}
                  >
                    {s.running ? 'RUNNING' : isEnabled ? 'ENABLED' : 'DISABLED'}
                  </span>
                </td>
                <td className="py-2">
                  <button
                    onClick={() => handleToggle(s.node_id, s)}
                    disabled={isPending}
                    className={`text-xs px-3 py-1 rounded border transition-colors ${
                      isPending
                        ? 'opacity-50 cursor-not-allowed'
                        : isEnabled
                          ? 'border-red-500/40 text-red-600 hover:bg-red-500/10'
                          : 'border-green-500/40 text-green-600 hover:bg-green-500/10'
                    }`}
                  >
                    {isPending ? '...' : isEnabled ? 'Disable' : 'Enable'}
                  </button>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
