module.exports = {
  apps: [
    {
      name: "cortextos-daemon",
      script: "/home/claude-dev/cortextos/dist/daemon.js",
      args: "--instance default",
      cwd: "/home/claude-dev/cortextos",
      env: {
        CTX_INSTANCE_ID: "default",
        CTX_ROOT: "/home/claude-dev/.cortextos/default",
        CTX_FRAMEWORK_ROOT: "/home/claude-dev/cortextos",
        CTX_PROJECT_ROOT: "/home/claude-dev/cortextos",
        CTX_ORG: "prop-firm-admin"
      },
      max_restarts: 10,
      restart_delay: 5000,
      autorestart: true
    },
    {
      name: "cortextos-dashboard",
      script: "node_modules/.bin/next",
      args: "dev --port 3000",
      cwd: "/home/claude-dev/cortextos/dashboard",
      env: {
        NODE_ENV: "development",
        PORT: "3000",
        CTX_ROOT: "/home/claude-dev/.cortextos/default",
        CTX_FRAMEWORK_ROOT: "/home/claude-dev/cortextos"
      },
      max_restarts: 5,
      restart_delay: 5000,
      autorestart: true
    }
  ]
};
