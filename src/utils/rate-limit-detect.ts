import { readFileSync, statSync } from 'fs';

/**
 * Scan the tail of a log for Anthropic rate-limit signatures (5h limits,
 * weekly limits, "overloaded" errors, "used N% of your..." messages).
 *
 * Used by both the daemon's crash recovery path (agent-process.ts) and the
 * SessionEnd crash-alert hook (hooks/hook-crash-alert.ts) so they classify
 * the same exits the same way: a rate-limit-driven exit gets a long-wait
 * restart instead of being counted toward the daily crash budget.
 */
export function detectRateLimitInLog(logPath: string): boolean {
  try {
    const size = statSync(logPath).size;
    const readBytes = Math.min(size, 200 * 1024); // last 200 KB
    const fd = readFileSync(logPath);
    const slice = fd.slice(Math.max(0, fd.length - readBytes)).toString('utf-8');
    const text = slice.replace(/\x1b\[[0-9;]*[a-zA-Z]/g, '').toLowerCase();
    return (
      text.includes('overloaded_error') ||
      text.includes('rate_limit_error') ||
      text.includes('rate limit') ||
      text.includes('rate-limit') ||
      text.includes('too many requests') ||
      text.includes('quota exceeded') ||
      text.includes('usage limit') ||
      text.includes('weekly limit') ||
      text.includes('5-hour limit') ||
      text.includes('5h limit') ||
      /used \d+% of your/.test(text)
    );
  } catch {
    return false;
  }
}

/**
 * How long to wait before retrying after a rate-limit-classified exit.
 * Anthropic 5h limits reset hourly-ish; weekly limits don't reset same-day
 * but the daemon should still poll at this cadence so the agent comes back
 * promptly when the window does open. 60 minutes is a reasonable balance:
 * fast enough that a 5h-window expiry surfaces inside the hour, slow enough
 * that we're not slamming the API during a hard cap.
 */
export const RATE_LIMIT_RETRY_MS = 60 * 60 * 1000;
