import { NextResponse } from 'next/server';
import { readState } from '@/lib/nt8-state';

export const dynamic = 'force-dynamic';

/**
 * GET /api/nt8/state[?node_id=vps1]
 *
 * Returns current NT8 state for all nodes (or filtered by node_id).
 * Authenticated — dashboard users only.
 *
 * Nodes not seen in the last 30 seconds are marked as stale/offline in the response.
 */
export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const nodeId = searchParams.get('node_id') ?? null;

  const state = readState();
  const now = Date.now();
  const STALE_MS = 30_000;

  // Mark nodes that haven't reported recently as offline
  for (const node of Object.values(state.nodes)) {
    const age = now - new Date(node.last_seen).getTime();
    if (age > STALE_MS) {
      node.connection = 'offline';
    }
  }

  if (nodeId) {
    const node = state.nodes[nodeId] ?? null;
    return NextResponse.json({ node, updated_at: state.updated_at });
  }

  return NextResponse.json({
    nodes: Object.values(state.nodes),
    updated_at: state.updated_at,
  });
}
