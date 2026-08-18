#!/usr/bin/env python3
"""
Standalone Taskmaster decision poller.
Polls TASKMASTER_BOT_TOKEN for callback_query events and resolves decisions
in pending-decisions.json.
"""
import json, os, re, time, sys, requests
from pathlib import Path
from datetime import datetime, timezone

TASKMASTER_BOT_TOKEN = os.environ.get('TASKMASTER_BOT_TOKEN')
if not TASKMASTER_BOT_TOKEN:
    print('ERROR: TASKMASTER_BOT_TOKEN not set', file=sys.stderr)
    sys.exit(1)
CTX_ROOT = os.environ.get('CTX_ROOT', os.path.expanduser('~/.cortextos/default'))
FRAMEWORK_ROOT = os.environ.get('CTX_FRAMEWORK_ROOT', os.path.expanduser('~/cortextos'))
ORG = os.environ.get('CTX_ORG', 'prop-firm-admin')

BASE_URL = f'https://api.telegram.org/bot{TASKMASTER_BOT_TOKEN}'
DECISIONS_PATH = Path(CTX_ROOT) / 'state' / 'pending-decisions.json'
INBOX_BASE = Path(CTX_ROOT) / 'inbox'

def tg(method, **kwargs):
    r = requests.post(f'{BASE_URL}/{method}', json=kwargs, timeout=10)
    return r.json()

def answer_callback(callback_query_id, text='Got it'):
    tg('answerCallbackQuery', callback_query_id=callback_query_id, text=text)

def edit_message(chat_id, message_id, text):
    try:
        tg('editMessageText', chat_id=chat_id, message_id=message_id, text=text)
    except Exception:
        pass

def load_decisions():
    if not DECISIONS_PATH.exists():
        return {'decisions': []}
    with open(DECISIONS_PATH) as f:
        return json.load(f)

def save_decisions(data):
    tmp = str(DECISIONS_PATH) + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, str(DECISIONS_PATH))

def notify_agent(agent, decision_id, chosen, title):
    """Write a message to the agent's inbox."""
    inbox_dir = INBOX_BASE / agent
    if not inbox_dir.exists():
        return
    ts = int(time.time() * 1000)
    msg_id = f'{ts}-taskmaster-{decision_id[-6:]}'
    msg = {
        'id': msg_id,
        'from': 'taskmaster',
        'to': agent,
        'priority': 'normal',
        'text': f'Decision resolved: {title}\nChosen: {chosen}\nID: {decision_id}',
        'created_at': datetime.now(timezone.utc).isoformat(),
    }
    msg_file = inbox_dir / f'{msg_id}.json'
    with open(msg_file, 'w') as f:
        json.dump(msg, f, indent=2)

def resolve_decision(decision_id, option_index):
    data = load_decisions()
    for d in data['decisions']:
        if d.get('id') == decision_id and d.get('status') == 'pending':
            options = d.get('options', ['YES', 'NO', 'HOLD'])
            if option_index >= len(options):
                return None, None
            chosen = options[option_index]
            d['status'] = 'resolved'
            d['chosen'] = chosen
            d['resolved_at'] = datetime.now(timezone.utc).isoformat()
            d['resolved_note'] = 'Resolved via Telegram button'
            save_decisions(data)
            # Notify requesting agent
            agent = d.get('agent')
            if agent:
                notify_agent(agent, decision_id, chosen, d.get('title', ''))
            return chosen, d.get('title', decision_id)
    return None, None

def poll():
    offset = None
    print(f'[taskmaster-poller] Starting. DECISIONS_PATH={DECISIONS_PATH}', flush=True)
    
    while True:
        try:
            params = {
                'timeout': 30,
                'allowed_updates': ['callback_query'],
            }
            if offset is not None:
                params['offset'] = offset
            
            r = requests.get(f'{BASE_URL}/getUpdates', params=params, timeout=40)
            data = r.json()
            
            if not data.get('ok'):
                print(f'[taskmaster-poller] getUpdates error: {data}', flush=True)
                time.sleep(5)
                continue
            
            for update in data.get('result', []):
                offset = update['update_id'] + 1
                
                cq = update.get('callback_query')
                if not cq:
                    continue
                
                cb_data = cq.get('data', '')
                # callback_data = "decision_" + decisionId + "_" + optionIndex
                # decisionId = "decision_{epoch}_{rand}", so full string = "decision_decision_{epoch}_{rand}_{opt}"
                m = re.match(r'^decision_(decision_\d+_[a-z0-9]+)_(\d+)$', cb_data)
                if not m:
                    print(f'[taskmaster-poller] Unknown callback: {cb_data}', flush=True)
                    continue
                
                decision_id = m.group(1)
                option_index = int(m.group(2))
                cq_id = cq['id']
                chat_id = cq.get('message', {}).get('chat', {}).get('id')
                message_id = cq.get('message', {}).get('message_id')
                from_user = cq.get('from', {})
                username = from_user.get('username') or from_user.get('first_name', 'User')
                
                print(f'[taskmaster-poller] Decision callback: {decision_id} option={option_index} from={username}', flush=True)
                
                chosen, title = resolve_decision(decision_id, option_index)
                if chosen:
                    answer_callback(cq_id, f'Recorded: {chosen}')
                    if chat_id and message_id:
                        edit_message(chat_id, message_id, f'✅ {chosen} — by {username}')
                    print(f'[taskmaster-poller] Resolved {decision_id}: {chosen} ({title})', flush=True)
                else:
                    answer_callback(cq_id, 'Already resolved or not found')
                    print(f'[taskmaster-poller] Decision not found or already resolved: {decision_id}', flush=True)
        
        except requests.exceptions.Timeout:
            pass  # Normal for long-poll timeout
        except Exception as e:
            print(f'[taskmaster-poller] Error: {e}', flush=True)
            time.sleep(3)

if __name__ == '__main__':
    poll()
