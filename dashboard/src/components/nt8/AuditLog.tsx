'use client';

import type { Nt8Event } from './types';

interface Props {
  events: Nt8Event[];
}

const EVENT_LABELS: Record<string, { label: string; class: string }> = {
  auto_restore: { label: 'Auto-Restore', class: 'bg-green-500/10 text-green-600 dark:text-green-400' },
  restore_failed: { label: 'Restore Failed', class: 'bg-red-500/10 text-red-600 dark:text-red-400' },
  error: { label: 'Error', class: 'bg-yellow-500/10 text-yellow-600 dark:text-yellow-400' },
};

function formatTs(ts: string): string {
  try {
    return new Date(ts).toLocaleString();
  } catch {
    return ts;
  }
}

export function AuditLog({ events }: Props) {
  if (events.length === 0) {
    return (
      <div className="text-sm text-muted-foreground py-4 text-center">
        No audit events
      </div>
    );
  }

  return (
    <div className="space-y-2">
      {events.map((event, i) => {
        const style = EVENT_LABELS[event.type] ?? {
          label: event.type,
          class: 'bg-muted text-muted-foreground',
        };

        return (
          <div key={i} className="flex items-start gap-3 text-sm py-2 border-b last:border-0">
            <span
              className={`shrink-0 inline-flex items-center text-xs font-medium rounded-full px-2 py-0.5 mt-0.5 ${style.class}`}
            >
              {style.label}
            </span>
            <div className="flex-1 min-w-0">
              <div className="font-mono text-xs text-muted-foreground">{event.node_id}</div>
              {event.account && (
                <div className="truncate">{event.account}</div>
              )}
              {event.strategies_restored && event.strategies_restored.length > 0 && (
                <div className="text-xs text-muted-foreground">
                  Restored: {event.strategies_restored.join(', ')}
                </div>
              )}
              {event.message && (
                <div className="text-xs text-muted-foreground truncate">{event.message}</div>
              )}
            </div>
            <div className="shrink-0 text-xs text-muted-foreground">{formatTs(event.timestamp)}</div>
          </div>
        );
      })}
    </div>
  );
}
