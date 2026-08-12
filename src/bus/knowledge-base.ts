import { execFileSync } from 'child_process';
import { existsSync, mkdirSync, readFileSync, statSync } from 'fs';
import { basename, join } from 'path';
import { homedir } from 'os';
import type { BusPaths } from '../types/index.js';
import { normalizeOrgName } from '../utils/org.js';

/**
 * Knowledge base integration — calls mmrag.py directly (cross-platform,
 * no bash dependency).  Previously wrapped kb-*.sh bash scripts.
 */

/**
 * Resolve the Python interpreter inside the knowledge-base venv,
 * accounting for Windows vs Unix layout.
 */
function getVenvPython(frameworkRoot: string): string {
  const isWin = process.platform === 'win32';
  const venvBin = isWin ? 'Scripts' : 'bin';
  const pythonExe = isWin ? 'python.exe' : 'python3';
  return join(frameworkRoot, 'knowledge-base', 'venv', venvBin, pythonExe);
}

/**
 * Load .env and secrets.env files the same way the bash scripts did
 * (`set -o allexport && source …`).  Returns a flat key→value map.
 */
function loadSecretsEnv(frameworkRoot: string, org: string): Record<string, string> {
  const secretsPath = join(frameworkRoot, 'orgs', org, 'secrets.env');
  const dotenvPath = join(frameworkRoot, '.env');
  const vars: Record<string, string> = {};
  for (const p of [dotenvPath, secretsPath]) {
    if (existsSync(p)) {
      for (const line of readFileSync(p, 'utf-8').split('\n')) {
        const trimmed = line.trim();
        if (!trimmed || trimmed.startsWith('#')) continue;
        const idx = trimmed.indexOf('=');
        if (idx > 0) {
          let val = trimmed.slice(idx + 1);
          // Strip surrounding quotes (single or double) that some .env files use
          if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
            val = val.slice(1, -1);
          }
          vars[trimmed.slice(0, idx)] = val;
        }
      }
    }
  }
  return vars;
}

/**
 * Check whether the knowledge base config file exists for a given env.
 *
 * The Python MMRAG tool loads its config from env.MMRAG_CONFIG
 * (`knowledge-base/config.json` under the org's state dir) and exits with
 * "Config not found. Run setup first" if the file is absent. When that
 * happens, execFileSync throws a non-zero-exit error which — if not caught
 * — produces a user-facing unhandled-throw stack dump on top of the
 * already-printed Python error. This helper lets callers detect the
 * missing-config state UP FRONT and respond gracefully (warn + return)
 * instead of relying on brittle stderr string matching after the throw.
 */
function kbConfigured(env: Record<string, string>): boolean {
  return existsSync(env.MMRAG_CONFIG);
}

/**
 * Build the full env object needed by mmrag.py calls.
 */
function buildKBEnv(
  frameworkRoot: string,
  org: string,
  instanceId: string,
  agent?: string,
): Record<string, string> {
  // Normalize org to its canonical filesystem casing BEFORE touching any
  // paths. Without this, a lowercase --org arg produces a ghost state dir
  // (~/.cortextos/<instance>/orgs/<lowercase>/knowledge-base/) with its own
  // MMRAG config.json, splitting KB state across two directories and
  // polluting dashboard sync with hits against a non-existent org.
  const canonicalOrg = normalizeOrgName(frameworkRoot, org);
  const kbRoot = join(homedir(), '.cortextos', instanceId, 'orgs', canonicalOrg, 'knowledge-base');
  const secrets = loadSecretsEnv(frameworkRoot, canonicalOrg);
  return {
    ...process.env as Record<string, string>,
    ...secrets,
    CTX_ORG: canonicalOrg,
    CTX_AGENT_NAME: agent || '',
    CTX_INSTANCE_ID: instanceId,
    CTX_FRAMEWORK_ROOT: frameworkRoot,
    MMRAG_DIR: kbRoot,
    MMRAG_CHROMADB_DIR: join(kbRoot, 'chromadb'),
    MMRAG_CONFIG: join(kbRoot, 'config.json'),
  };
}

export interface KBQueryResult {
  content: string;
  source_file: string;
  agent_name?: string;
  org: string;
  score: number;
  doc_type: string;
}

export interface KBQueryResponse {
  results: KBQueryResult[];
  total: number;
  query: string;
  collection: string;
  /**
   * True when at least one collection probe failed (timeout, python error) and
   * its results are therefore MISSING rather than absent. An empty `results`
   * with `degraded: true` means "we do not know", never "there is nothing".
   * Callers that report absence to a human must check this first.
   */
  degraded?: boolean;
  degradedReason?: string;
  /**
   * What each searched collection contributed. Present so a caller can tell a
   * total that came from every collection from one where a collection returned
   * nothing — the two are the same number and read the same without this.
   */
  perCollection?: Array<{ collection: string; count: number }>;
}

/**
 * Query the knowledge base.
 * Returns parsed JSON results when --json is used internally.
 */
export function queryKnowledgeBase(
  paths: BusPaths,
  question: string,
  options: {
    org: string;
    agent?: string;
    scope?: 'shared' | 'private' | 'all';
    topK?: number;
    threshold?: number;
    frameworkRoot: string;
    instanceId: string;
  },
): KBQueryResponse {
  const { agent, scope = 'all', topK = 5, threshold = 0.5, frameworkRoot, instanceId } = options;
  // Normalize once at the top so every downstream path join, env var, and
  // ChromaDB collection name uses the canonical filesystem casing. Without
  // this, `shared-acmecorp` and `shared-AcmeCorp` become two
  // distinct ChromaDB collections and a case-drifted query silently hits
  // the wrong one.
  const org = normalizeOrgName(frameworkRoot, options.org);

  const env = buildKBEnv(frameworkRoot, org, instanceId, agent);

  // UX safety net: if the KB is not configured for this org (no config.json
  // on disk yet), skip the python probe entirely and return empty results
  // with a visible warning. Previously the inner runQuery() try/catch would
  // swallow the Config-not-found error silently and the operator would see
  // "0 results" with no hint about WHY — indistinguishable from a legitimate
  // empty query against a configured KB. The warn-and-empty shape makes the
  // distinction obvious and actionable.
  if (!kbConfigured(env)) {
    console.warn(
      `[kb] Knowledge base not configured for org ${org}. Returning empty results — run setup to enable.`,
    );
    return { results: [], total: 0, query: question, collection: `shared-${org}` };
  }

  const pythonPath = getVenvPython(frameworkRoot);
  const mmragPath = join(frameworkRoot, 'knowledge-base', 'scripts', 'mmrag.py');

  // Determine which collections to query based on scope
  const collections: string[] = [];
  switch (scope) {
    case 'shared':
      collections.push(`shared-${org}`);
      break;
    case 'private':
      collections.push(agent ? `agent-${agent}` : `shared-${org}`);
      break;
    case 'all':
      collections.push(`shared-${org}`);
      if (agent) collections.push(`agent-${agent}`);
      break;
  }

  // A query embeds the question via Gemini and then searches a collection that
  // grows without bound. The old cap was 30s, chosen when the collections were
  // small, and it silently became the dominant source of "0 results": on
  // 2026-08-12 shared-prop-firm-admin (1045 chunks) answered the SAME query in
  // 28.1s from one agent and 61s from another. The 61s run timed out, threw,
  // and was swallowed into an empty result — while the 28.1s run returned five
  // hits scoring 0.71–0.79. Same collection, same question, opposite verdicts,
  // both exit 0. Mirror the ingest path: generous default, env override,
  // floored so nobody can set it below one Gemini round-trip.
  const KB_QUERY_TIMEOUT_FLOOR_MS = 30_000;
  const KB_QUERY_TIMEOUT_DEFAULT_MS = 180_000;
  const requestedQueryTimeout = Number(process.env.KB_QUERY_TIMEOUT_MS);
  const queryTimeoutMs = Math.max(
    KB_QUERY_TIMEOUT_FLOOR_MS,
    Number.isFinite(requestedQueryTimeout) && requestedQueryTimeout > 0
      ? requestedQueryTimeout
      : KB_QUERY_TIMEOUT_DEFAULT_MS,
  );

  // Set when a collection probe fails outright (timeout, python error, OOM).
  // This is the load-bearing part of the fix, not the larger timeout: a raised
  // cap makes failure rarer, but only this makes it VISIBLE. An empty answer
  // from a broken retriever and an empty answer from an empty collection are
  // the same value, and callers have repeatedly read the first as the second
  // and concluded a document was deleted.
  let degraded = false;
  let degradedReason = '';
  const perCollection: Array<{ collection: string; count: number }> = [];

  const runQuery = (col: string): string | null => {
    try {
      return execFileSync(pythonPath, [
        mmragPath, 'query', question,
        '--collection', col,
        '--top-k', String(topK),
        '--threshold', String(threshold),
        '--json',
      ], {
        encoding: 'utf-8',
        timeout: queryTimeoutMs,
        env,
      });
    } catch (err) {
      degraded = true;
      const e = err as { code?: string; signal?: string; message?: string };
      // execFileSync surfaces a timeout kill as SIGTERM, not as an error code.
      const timedOut = e?.signal === 'SIGTERM' || e?.code === 'ETIMEDOUT';
      degradedReason = timedOut
        ? `query to ${col} exceeded ${queryTimeoutMs}ms and was killed`
        : `query to ${col} failed: ${e?.message?.split('\n')[0] ?? 'unknown error'}`;
      console.warn(
        `[kb] DEGRADED — ${degradedReason}. This is NOT a confirmed empty result; ` +
        `do not conclude a document is absent from it. Retry, or raise KB_QUERY_TIMEOUT_MS.`,
      );
      return null;
    }
  };

  // Marks a collection whose output could not be understood. Distinct from
  // runQuery's failure: there, python died and we know it. Here python exited
  // 0 and we could not read what it said, which USED to be indistinguishable
  // from "it said nothing" — the same defect as the swallowed timeout, one
  // layer up, and the only remaining path that could produce a confident empty
  // without setting the flag.
  const markUnreadable = (col: string, why: string): void => {
    degraded = true;
    degradedReason = `output from ${col} was unreadable (${why})`;
    console.warn(
      `[kb] DEGRADED — ${degradedReason}. This is NOT a confirmed empty result.`,
    );
  };

  const parseOutput = (output: string | null, col: string): KBQueryResult[] => {
    // null means runQuery already failed and already flagged it.
    if (!output) return [];
    // mmrag.py --json outputs pretty-printed JSON; find and parse the JSON block
    const trimmed = output.trim();
    const jsonStart = trimmed.indexOf('{');
    if (jsonStart === -1) {
      markUnreadable(col, 'no JSON object in output');
      return [];
    }
    try {
      const raw = JSON.parse(trimmed.slice(jsonStart)) as {
        results?: Array<{ content?: string; result?: string; similarity?: number; source?: string; type?: string }>;
        result_count?: number;
        query?: string;
        collection?: string;
      };
      return (raw.results || []).map((r) => ({
        content: r.content || r.result || '',
        source_file: r.source || '',
        org,
        agent_name: agent,
        score: r.similarity ?? 0,
        doc_type: r.type || 'markdown',
      }));
    } catch (e) {
      markUnreadable(col, `malformed JSON: ${(e as Error)?.message?.split('\n')[0] ?? 'parse error'}`);
      return [];
    }
  };

  try {
    let allResults: KBQueryResult[] = [];
    let lastCollection = `shared-${org}`;
    for (const col of collections) {
      const output = runQuery(col);
      const rows = parseOutput(output, col);
      // Record what each collection actually contributed. A total is not an
      // account of its parts: "(5/5)" reads as a complete answer whether the
      // second collection returned nothing legitimately or was never searched.
      perCollection.push({ collection: col, count: rows.length });
      allResults = allResults.concat(rows);
      lastCollection = col;
    }

    if (allResults.length > 0) {
      return {
        results: allResults,
        total: allResults.length,
        query: question,
        collection: collections.length === 1 ? lastCollection : `shared-${org}`,
        ...(perCollection.length > 0 ? { perCollection } : {}),
        ...(degraded ? { degraded, degradedReason } : {}),
      };
    }
  } catch (err) {
    degraded = true;
    degradedReason = (err as Error)?.message?.split('\n')[0] ?? 'unknown error';
  }

  return {
    results: [],
    total: 0,
    query: question,
    collection: `shared-${org}`,
    ...(degraded ? { degraded, degradedReason } : {}),
  };
}

/**
 * Ingest files into the knowledge base.
 */
/**
 * Print the top-3 existing KB documents nearest to each incoming source.
 *
 * CONTRACT: this function is advisory and MUST NOT be able to fail an ingest.
 * Every failure path — unreadable file, directory, unconfigured KB, python
 * error, malformed response — degrades to silence or a one-line note and
 * returns. It never throws and never changes the exit code. If it becomes
 * capable of blocking, it has been broken.
 *
 * Matching is on CONTENT, not filename: the collisions this exists to prevent
 * were files with different names saying the same thing.
 */
function printNeighbours(
  paths: string[],
  ctx: {
    org: string;
    agent?: string;
    frameworkRoot: string;
    instanceId: string;
    collection: string;
  },
): void {
  // A probe large enough to characterise the document, small enough to stay a
  // cheap embedding. Front matter plus opening prose is where a rule file
  // states its subject.
  const PROBE_CHARS = 1200;
  const TOP_N = 3;

  for (const p of paths) {
    let probe = '';
    try {
      if (!existsSync(p)) continue;
      if (statSync(p).isDirectory()) continue; // per-file only; a dir has no single subject
      probe = readFileSync(p, 'utf-8').slice(0, PROBE_CHARS).trim();
    } catch {
      continue; // unreadable: not our business to report, and not worth failing over
    }
    if (probe.length === 0) continue;

    let res: KBQueryResponse;
    try {
      res = queryKnowledgeBase({} as BusPaths, probe, {
        org: ctx.org,
        agent: ctx.agent,
        scope: 'shared',
        // Over-fetch: results are CHUNKS and several may share one file, so
        // asking for exactly TOP_N would yield fewer than TOP_N distinct documents.
        topK: TOP_N * 4,
        // No threshold. The whole point is to show what is nearest, whatever
        // that is — a low score is itself information ("nothing like this
        // exists yet"), and a threshold would hide exactly the borderline case
        // a human should judge.
        threshold: 0,
        frameworkRoot: ctx.frameworkRoot,
        instanceId: ctx.instanceId,
      });
    } catch {
      continue; // KB unavailable — ingest proceeds regardless
    }

    // Never show a file as its own neighbour on re-ingest.
    //
    // DEDUPE BY DOCUMENT, not by chunk. The KB returns chunks, so a single
    // strongly-matching file can occupy every slot and hide the second and
    // third distinct neighbours — which are the ones that reveal a spread of
    // near-duplicates rather than one. Observed on the first live run: one
    // file took 2 of 3 slots. Keep each document's best-scoring chunk.
    const best = new Map<string, KBQueryResult>();
    for (const r of res?.results ?? []) {
      if (!r.source_file || r.source_file === p) continue;
      const prev = best.get(r.source_file);
      if (!prev || (r.score ?? 0) > (prev.score ?? 0)) best.set(r.source_file, r);
    }
    const hits = [...best.values()]
      .sort((a, b) => (b.score ?? 0) - (a.score ?? 0))
      .slice(0, TOP_N);

    console.log(`\n[kb] Nearest existing documents to ${basename(p)}:`);
    if (hits.length === 0) {
      console.log('       (none — nothing similar in the shared KB yet)');
    } else {
      for (const h of hits) {
        const name = basename(h.source_file || '(unknown)');
        const score = typeof h.score === 'number' ? h.score.toFixed(3) : '—';
        const who = h.agent_name ? ` · ${h.agent_name}` : '';
        console.log(`       ${score}  ${name}${who}`);
      }
      console.log('       ^ informational only — ingest proceeds. Check these before adding a near-duplicate.');
    }
  }
}

export function ingestKnowledgeBase(
  paths: string[],
  options: {
    org: string;
    agent?: string;
    scope?: 'shared' | 'private';
    force?: boolean;
    frameworkRoot: string;
    instanceId: string;
  },
): void {
  const { agent, scope = 'shared', force, frameworkRoot, instanceId } = options;
  // Normalize once (see queryKnowledgeBase for rationale).
  const org = normalizeOrgName(frameworkRoot, options.org);

  const env = buildKBEnv(frameworkRoot, org, instanceId, agent);

  // Correctness fix: if the KB is not configured for this org, the underlying
  // python MMRAG tool exits with "Config not found. Run setup first" and
  // execFileSync (below, stdio: inherit) throws a non-zero-exit error. That
  // throw used to bubble up through the CLI action handler as an unhandled
  // exception, dumping a full Node stack trace on top of the python error
  // message — ugly and alarming for operators who were just running ingest
  // without setting up the KB first. Detect the missing-config state
  // up-front and warn-and-skip instead of letting execFileSync crash.
  if (!kbConfigured(env)) {
    console.warn(
      `[kb] Knowledge base not configured for org ${org}. Skipping ingest — ` +
      `run setup to enable (see HEARTBEAT.md step 10 for the config path).`,
    );
    return;
  }

  const pythonPath = getVenvPython(frameworkRoot);
  const mmragPath = join(frameworkRoot, 'knowledge-base', 'scripts', 'mmrag.py');

  // Determine collection name (same logic as kb-ingest.sh)
  let collection: string;
  if (scope === 'private') {
    if (!agent) throw new Error('--agent or CTX_AGENT_NAME required for --scope private');
    collection = `agent-${agent}`;
  } else {
    collection = `shared-${org}`;
  }

  // Ensure chromadb dir exists
  const kbRoot = join(homedir(), '.cortextos', instanceId, 'orgs', org, 'knowledge-base');
  const chromaDir = join(kbRoot, 'chromadb');
  if (!existsSync(chromaDir)) {
    mkdirSync(chromaDir, { recursive: true });
  }

  console.log(`Ingesting into collection: ${collection}`);
  for (const p of paths) {
    console.log(`  Source: ${p}`);
  }

  // ── Neighbour display ───────────────────────────────────────────────────
  // Show what already exists near this content, BEFORE writing it.
  //
  // WHY THIS IS UNCONDITIONAL AND NEVER BLOCKS
  // On 2026-08-12 devops and braindump collided three times in one day writing
  // near-duplicate rule files — twice ~30 min apart, and once where BOTH agents
  // had announced their plan and complied with the announce-first rule, then each
  // executed the option the other had rejected. Announcing a PLAN is not
  // announcing an ACT, and neither re-checked between saying and doing. Prose
  // cannot close a timing hole; a check at the moment of writing can.
  //
  // Chief's framing: "Three collisions in one day is not an argument for more
  // discipline — it is an argument for a different mechanism."
  //
  // So: INFORMATION, NEVER OBSTACLE. No threshold, no prompt, no flag, no exit
  // code. It prints neighbours and proceeds. A check that can block would grow a
  // --no-verify escape hatch within a week and be pasted reflexively thereafter;
  // one that only informs stays useful because it never costs anything to leave on.
  //
  // NOT skipped on --force. It was, on the reasoning that --force means a
  // deliberate re-ingest of a source already in the KB, so the operator has
  // already seen its neighbours. That reasoning was wrong about how --force is
  // actually used: braindump observed on 2026-08-12 that every new rule file it
  // ingested that day passed --force on the source's FIRST ingest — including
  // the duplicate the collision check exists to catch. Gating on the flag
  // therefore disabled the check in precisely the case it was built for.
  //
  // The flag says how to write, not whether the source is new, and only the
  // latter would justify skipping. Since printNeighbours already excludes the
  // file from its own results, a true re-ingest just shows its other
  // neighbours — one query's cost, already accepted on every non-force ingest.
  // So it runs unconditionally for shared scope.
  if (scope === 'shared') {
    printNeighbours(paths, {
      org,
      agent,
      frameworkRoot,
      instanceId,
      collection,
    });
  }

  const args = [mmragPath, 'ingest', ...paths, '--collection', collection];
  if (force) args.push('--force');

  // Multimodal PDF ingestion via Gemini Flash routinely takes 2–5 min for
  // documents over ~10 pages with images/tables. Two minutes was too low and
  // produced ETIMEDOUT mid-Gemini-call. Default 10 min, override via env,
  // floored at 60s so nobody accidentally sets it to 0 or a value smaller
  // than a single Gemini call needs.
  const KB_INGEST_TIMEOUT_FLOOR_MS = 60_000;
  const KB_INGEST_TIMEOUT_DEFAULT_MS = 600_000;
  const requestedTimeout = Number(process.env.KB_INGEST_TIMEOUT_MS);
  const ingestTimeoutMs = Math.max(
    KB_INGEST_TIMEOUT_FLOOR_MS,
    Number.isFinite(requestedTimeout) && requestedTimeout > 0
      ? requestedTimeout
      : KB_INGEST_TIMEOUT_DEFAULT_MS,
  );

  execFileSync(pythonPath, args, {
    encoding: 'utf-8',
    timeout: ingestTimeoutMs,
    env,
    stdio: 'inherit',
  });

  console.log(`\nIngest complete → collection: ${collection}`);
}

/**
 * Ensure the knowledge base directories exist for an org.
 *
 * `frameworkRoot` is required so the org name can be normalized to its
 * canonical filesystem casing — without that, a caller passing a drifted
 * name (e.g. "acmecorp") would create a ghost state dir identical
 * to the one this module was written to prevent.
 */
export function ensureKBDirs(instanceId: string, frameworkRoot: string, org: string): void {
  const canonicalOrg = normalizeOrgName(frameworkRoot, org);
  const kbRoot = join(homedir(), '.cortextos', instanceId, 'orgs', canonicalOrg, 'knowledge-base');
  const chromaDir = join(kbRoot, 'chromadb');
  if (!existsSync(chromaDir)) {
    mkdirSync(chromaDir, { recursive: true });
  }
}
