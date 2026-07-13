import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const isDevelopment = process.env.NODE_ENV === "development";
const nativeAuthCSP = [
  "default-src 'none'",
  "base-uri 'none'",
  "object-src 'none'",
  "frame-ancestors 'none'",
  "form-action 'none'",
  `script-src 'self' 'unsafe-inline'${isDevelopment ? " 'unsafe-eval'" : ""}`,
  "style-src 'self' 'unsafe-inline'",
  `connect-src 'self'${isDevelopment ? " ws: wss:" : ""}`,
  "img-src 'self' data:",
  "font-src 'self'"
].join("; ");

/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  devIndicators: false,
  turbopack: {
    root
  },
  async headers() {
    return [
      {
        // Next's streamed app payload currently requires inline scripts. This
        // still confines the passkey ceremony to same-origin code and network
        // requests while blocking plugins, framing, forms, and base-tag pivots.
        source: "/auth/native",
        headers: [
          { key: "Content-Security-Policy", value: nativeAuthCSP }
        ]
      },
      {
        source: "/:path*",
        headers: [
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "X-Frame-Options", value: "DENY" },
          { key: "Referrer-Policy", value: "no-referrer" },
          { key: "Permissions-Policy", value: "geolocation=(), camera=(), microphone=()" }
        ]
      }
    ];
  }
};

export default nextConfig;
