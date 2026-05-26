'use client';

import type { NodeState } from './types';

interface Props {
  nodes: NodeState[];
}

export function NodeStatus({ nodes }: Props) {
  if (nodes.length === 0) {
    return (
      <div className="text-sm text-muted-foreground px-1">
        No nodes connected
      </div>
    );
  }

  return (
    <div className="flex gap-3 flex-wrap">
      {nodes.map((node) => (
        <div key={node.node_id} className="flex items-center gap-2 text-sm">
          <span
            className={`inline-block w-2 h-2 rounded-full ${
              node.connection === 'online' ? 'bg-green-500' : 'bg-red-500'
            }`}
          />
          <span className="font-mono">{node.node_id}</span>
          <span className="text-muted-foreground">
            {node.connection === 'online'
              ? `online · ${node.strategies.length} strategies`
              : 'offline'}
          </span>
        </div>
      ))}
    </div>
  );
}
