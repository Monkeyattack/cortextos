import { NextResponse } from 'next/server';
import { readState, writeState } from '@/lib/nt8-state';
import type { StrategyInstance, Position } from '@/lib/nt8-state';

export const dynamic = 'force-dynamic';

/**
 * POST /api/nt8/state-update
 *
 * ATI Relay Agent pushes state every 5s (unauthenticated — from VPS, no auth header).
 * Updates node state in /tmp/nt8_state.json.
 *
 * Body: {
 *   node_id: string,
 *   timestamp: string,
 *   strategies: StrategyInstance[],
 *   positions: Position[],
 *   errors: string[],
 *   connection: "online" | "offline"
 * }
 */
export async function POST(request: Request) {
  let body: {
    node_id?: string;
    timestamp?: string;
    strategies?: StrategyInstance[];
    positions?: Position[];
    errors?: string[];
    connection?: string;
  };

  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const { node_id, timestamp, strategies, positions, errors, connection } = body;

  if (!node_id || typeof node_id !== 'string') {
    return NextResponse.json({ error: 'node_id is required' }, { status: 400 });
  }

  const state = readState();
  state.nodes[node_id] = {
    node_id,
    connection: (connection === 'offline' ? 'offline' : 'online') as 'online' | 'offline',
    last_seen: timestamp ?? new Date().toISOString(),
    strategies: strategies ?? [],
    positions: positions ?? [],
    errors: errors ?? [],
  };
  state.updated_at = new Date().toISOString();

  try {
    writeState(state);
  } catch (err) {
    return NextResponse.json({ error: `State write failed: ${err}` }, { status: 500 });
  }

  return NextResponse.json({ ok: true });
}
