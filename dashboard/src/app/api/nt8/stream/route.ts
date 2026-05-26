import { readState, readEvents } from '@/lib/nt8-state';

export const dynamic = 'force-dynamic';

/**
 * GET /api/nt8/stream
 *
 * SSE stream of NT8 state snapshots. Dashboard React components subscribe here
 * and get a push every 5s without polling from the browser.
 *
 * Authenticated (checked at middleware level).
 *
 * Event format: data: { nodes: NodeState[], events: Nt8Event[], updated_at: string }
 */
export async function GET() {
  const encoder = new TextEncoder();
  const INTERVAL_MS = 5_000;
  const STALE_MS = 30_000;

  let timer: ReturnType<typeof setInterval> | undefined;

  const stream = new ReadableStream({
    start(controller) {
      const send = () => {
        try {
          const state = readState();
          const now = Date.now();

          for (const node of Object.values(state.nodes)) {
            const age = now - new Date(node.last_seen).getTime();
            if (age > STALE_MS) {
              node.connection = 'offline';
            }
          }

          const events = readEvents();
          const payload = {
            nodes: Object.values(state.nodes),
            events: events.events.slice(-20).reverse(),
            updated_at: state.updated_at,
          };

          const data = `data: ${JSON.stringify(payload)}\n\n`;
          controller.enqueue(encoder.encode(data));
        } catch {
          // Non-fatal — skip this tick
        }
      };

      send();
      timer = setInterval(send, INTERVAL_MS);
    },
    cancel() {
      if (timer !== undefined) clearInterval(timer);
    },
  });

  return new Response(stream, {
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    },
  });
}
