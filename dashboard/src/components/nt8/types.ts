export interface StrategyInstance {
  strategy_name: string;
  account: string;
  instrument: string;
  status: string;
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

export interface Nt8Event {
  type: string;
  node_id: string;
  account?: string;
  strategies_restored?: string[];
  message?: string;
  timestamp: string;
}
