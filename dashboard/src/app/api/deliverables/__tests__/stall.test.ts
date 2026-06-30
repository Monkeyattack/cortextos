import { describe, it, expect, beforeEach, vi } from 'vitest';
import Database from 'better-sqlite3';
import { NextRequest } from 'next/server';

// Shared in-memory DB injected in place of the real SQLite singleton. Mirrors
// the deliverables schema from src/lib/db.ts (only the columns the GET route
// touches matter here).
const { testDb } = vi.hoisted(() => {
  const Db = require('better-sqlite3');
  const db = new Db(':memory:');
  db.exec(`
    CREATE TABLE deliverables (
      id TEXT PRIMARY KEY,
      sow_id TEXT,
      title TEXT,
      owner_agent TEXT,
      success_criteria TEXT NOT NULL DEFAULT '[]',
      status TEXT NOT NULL DEFAULT 'not_started',
      signed_off_by TEXT,
      signed_off_at TEXT,
      attempts INTEGER NOT NULL DEFAULT 0,
      last_run TEXT,
      org TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
  `);
  return { testDb: db as InstanceType<typeof Database> };
});

vi.mock('@/lib/db', () => ({ db: testDb }));

// Imported after the mock so the route binds to testDb.
import { GET } from '../route';

function seed(id: string, status: string, updated_at: string) {
  testDb
    .prepare(
      `INSERT INTO deliverables (id, sow_id, title, owner_agent, success_criteria, status, org, created_at, updated_at)
       VALUES (?, 'sow-1', ?, 'devops', '[]', ?, 'prop-firm-admin', ?, ?)`
    )
    .run(id, id, status, updated_at, updated_at);
}

async function fetchStalled(thresholdHours = 24): Promise<{ id: string }[]> {
  const url = `http://localhost/api/deliverables?stalled=true&threshold_hours=${thresholdHours}`;
  const res = await GET(new NextRequest(url));
  return (await res.json()) as { id: string }[];
}

function isoHoursAgo(hours: number): string {
  return new Date(Date.now() - hours * 3600 * 1000).toISOString();
}

describe('GET /api/deliverables?stalled=true', () => {
  beforeEach(() => {
    testDb.prepare('DELETE FROM deliverables').run();
  });

  it('flags an active deliverable updated just past the threshold (T/Z format regression)', async () => {
    // 26h old → genuinely stalled. The row is stored as an ISO string with the
    // 'T' separator + 'Z' suffix (new Date().toISOString()), which a raw
    // lexicographic compare against datetime('now') would silently miss.
    seed('d-stale', 'in_progress', isoHoursAgo(26));
    const ids = (await fetchStalled(24)).map(d => d.id);
    expect(ids).toContain('d-stale');
  });

  it('does not flag a fresh active deliverable inside the threshold', async () => {
    seed('d-fresh', 'in_progress', isoHoursAgo(6));
    const ids = (await fetchStalled(24)).map(d => d.id);
    expect(ids).not.toContain('d-fresh');
  });

  it('only considers active statuses (in_progress/needs_qa/qa_failed)', async () => {
    seed('d-active', 'needs_qa', isoHoursAgo(48));
    seed('d-done', 'signed_off', isoHoursAgo(48));
    seed('d-notstarted', 'not_started', isoHoursAgo(48));
    const ids = (await fetchStalled(24)).map(d => d.id);
    expect(ids).toContain('d-active');
    expect(ids).not.toContain('d-done');
    expect(ids).not.toContain('d-notstarted');
  });
});
