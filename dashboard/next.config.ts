import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  serverExternalPackages: ['better-sqlite3'],
  allowedDevOrigins: ['cc.profithits.app'],
  async headers() {
    return [
      {
        source: '/((?!_next/static).*)',
        headers: [
          { key: 'Cache-Control', value: 'no-store, must-revalidate' },
        ],
      },
    ];
  },
};

export default nextConfig;
