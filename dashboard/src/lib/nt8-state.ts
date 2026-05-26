import fs from 'fs';
import path from 'path';
import { randomUUID } from 'crypto';

export const STATE_PATH = path.join('/tmp', 'nt8_state.json');
export const COMMANDS_PATH = path.join('/tmp', 'nt8_commands.json');
export const EVENTS_PATH = path.join('/tmp', 'nt8_events.json');

const COMMAND_TTL_MS = 30_000;
const EVENTS_MAX = 200;

export interface StrategyInstance {
  strategy_name: string;
  account: string;
  instrument: string;
  status: string;   // 'Enabled' | 'Disabled'
  running: boolean;
}

export interface Position {
  account: string;
  instrument: string;
  quantity: number;
  entry_price: number;
  unrealized_pnl: number;
  market_price: number;
}

export interface NodeState {
  node_id: string;
  connection: 'online' | 'offline';
  last_seen: string;
  strategies: StrategyInstance[];
  positions: Position[];
  errors: string[];
}

export interface Nt8State {
  updated_at: string;
  nodes: Record<string, NodeState>;
}

export interface Nt8Command {
  id: string;
  node_id: string;
  type: 'enable_strategy' | 'disable_strategy';
  strategy_name: string;
  account: string;
  created_at: string;
  expires_at: string;
  acked: boolean;
  ack_success: boolean | null;
  ack_error: string | null;
}

export interface Nt8CommandQueue {
  commands: Nt8Command[];
}

export interface Nt8Event {
  type: string;
  node_id: string;
  account?: string;
  strategies_restored?: string[];
  message?: string;
  timestamp: string;
}

export interface Nt8EventLog {
  events: Nt8Event[];
}

function atomicWrite(filePath: string, data: unknown): void {
  const tmp = filePath + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2));
  fs.renameSync(tmp, filePath);
}

export function readState(): Nt8State {
  try {
    if (!fs.existsSync(STATE_PATH)) return { updated_at: new Date().toISOString(), nodes: {} };
    return JSON.parse(fs.readFileSync(STATE_PATH, 'utf-8'));
  } catch {
    return { updated_at: new Date().toISOString(), nodes: {} };
  }
}

export function writeState(state: Nt8State): void {
  atomicWrite(STATE_PATH, state);
}

export function readCommands(): Nt8CommandQueue {
  try {
    if (!fs.existsSync(COMMANDS_PATH)) return { commands: [] };
    return JSON.parse(fs.readFileSync(COMMANDS_PATH, 'utf-8'));
  } catch {
    return { commands: [] };
  }
}

export function writeCommands(queue: Nt8CommandQueue): void {
  atomicWrite(COMMANDS_PATH, queue);
}

export function readEvents(): Nt8EventLog {
  try {
    if (!fs.existsSync(EVENTS_PATH)) return { events: [] };
    return JSON.parse(fs.readFileSync(EVENTS_PATH, 'utf-8'));
  } catch {
    return { events: [] };
  }
}

export function appendEvent(event: Nt8Event): void {
  const log = readEvents();
  log.events.push(event);
  if (log.events.length > EVENTS_MAX) {
    log.events = log.events.slice(-EVENTS_MAX);
  }
  atomicWrite(EVENTS_PATH, log);
}

export function createCommand(
  node_id: string,
  type: 'enable_strategy' | 'disable_strategy',
  strategy_name: string,
  account: string,
): Nt8Command {
  const now = new Date();
  return {
    id: randomUUID(),
    node_id,
    type,
    strategy_name,
    account,
    created_at: now.toISOString(),
    expires_at: new Date(now.getTime() + COMMAND_TTL_MS).toISOString(),
    acked: false,
    ack_success: null,
    ack_error: null,
  };
}

export function pruneExpiredCommands(queue: Nt8CommandQueue): Nt8CommandQueue {
  const now = Date.now();
  return {
    commands: queue.commands.filter(
      (c) => !c.acked && new Date(c.expires_at).getTime() > now,
    ),
  };
}
