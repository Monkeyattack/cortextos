module.exports = {
  apps: [{
    name: 'untell-server',
    script: '/home/claude-dev/.claude/skills/untell/.venv/bin/uvicorn',
    args: 'untell.api_server:app --host 127.0.0.1 --port 8421 --workers 1',
    cwd: '/home/claude-dev/.claude/skills/untell',
    interpreter: 'none',
    env: {
      UNTELL_API_KEY: 'internal-prewarm',
      PYTHONPATH: '/home/claude-dev/.claude/skills/untell',
    },
    autorestart: true,
    watch: false,
    max_restarts: 10,
    restart_delay: 5000,
    log_file: '/home/claude-dev/.cortextos/default/logs/untell-server.log',
    error_file: '/home/claude-dev/.cortextos/default/logs/untell-server.err',
    out_file: '/home/claude-dev/.cortextos/default/logs/untell-server.out',
  }]
}
