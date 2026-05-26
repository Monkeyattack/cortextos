'use client';

import type { NodeState } from './types';

interface Props {
  nodes: NodeState[];
}

export function PositionsTable({ nodes }: Props) {
  const allPositions = nodes.flatMap((node) =>
    node.positions.map((p) => ({ ...p, node_id: node.node_id })),
  );

  if (allPositions.length === 0) {
    return (
      <div className="text-sm text-muted-foreground py-4 text-center">
        No open positions
      </div>
    );
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b text-muted-foreground text-left">
            <th className="py-2 pr-4 font-medium">Account</th>
            <th className="py-2 pr-4 font-medium">Instrument</th>
            <th className="py-2 pr-4 font-medium">Qty</th>
            <th className="py-2 pr-4 font-medium">Entry</th>
            <th className="py-2 pr-4 font-medium">Market</th>
            <th className="py-2 font-medium">Unrealized P&L</th>
          </tr>
        </thead>
        <tbody>
          {allPositions.map((p, i) => {
            const pnlPositive = p.unrealized_pnl >= 0;
            return (
              <tr key={i} className="border-b last:border-0 hover:bg-muted/30">
                <td className="py-2 pr-4 font-mono text-xs">{p.account}</td>
                <td className="py-2 pr-4 font-medium">{p.instrument}</td>
                <td className="py-2 pr-4">{p.quantity}</td>
                <td className="py-2 pr-4">${p.entry_price.toFixed(2)}</td>
                <td className="py-2 pr-4">${p.market_price.toFixed(2)}</td>
                <td
                  className={`py-2 font-medium ${
                    pnlPositive ? 'text-green-600 dark:text-green-400' : 'text-red-600 dark:text-red-400'
                  }`}
                >
                  {pnlPositive ? '+' : ''}${p.unrealized_pnl.toFixed(2)}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
