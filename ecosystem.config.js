module.exports = {
  "apps": [
    {
      "name": "cortextos-daemon",
      "script": "/home/claude-dev/cortextos/dist/daemon.js",
      "args": "--instance default",
      "cwd": "/home/claude-dev/cortextos",
      "env": {
        "CTX_INSTANCE_ID": "default",
        "CTX_ROOT": "/home/claude-dev/.cortextos/default",
        "CTX_FRAMEWORK_ROOT": "/home/claude-dev/cortextos",
        "CTX_PROJECT_ROOT": "/home/claude-dev/cortextos",
        "CTX_ORG": "prop-firm-admin"
      },
      "max_restarts": 10,
      "restart_delay": 5000,
      "autorestart": true
    }
  ]
};
