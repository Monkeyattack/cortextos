import { NextResponse } from 'next/server';
import { readCommands, writeCommands, pruneExpiredCommands } from '@/lib/nt8-state';

export const dynamic = 'force-dynamic';

/**
 * GET /api/nt8/pending-commands?node_id=vps1
 *
 * ATI Relay Agent polls every 2s to pick up pending commands (unauthenticated).
 * Returns un-acked, non-expired commands for the given node.
 * Expired commands are pruned on read.
 */
export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const node_id = searchParams.get('node_id');

  if (!node_id) {
    return NextResponse.json({ error: 'node_id is required' }, { status: 400 });
  }

  const queue = readCommands();
  const pruned = pruneExpiredCommands(queue);

  // Persist pruned state if anything was removed
  if (pruned.commands.length !== queue.commands.length) {
    try {
      writeCommands(pruned);
    } catch {
      // Non-fatal — serve stale data
    }
  }

  const pending = pruned.commands.filter((c) => c.node_id === node_id && !c.acked);

  return NextResponse.json({ commands: pending });
}
