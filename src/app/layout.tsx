import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Address Atlas",
  description: "Read-only multi-chain crypto portfolio tracker from wallet addresses.",
  openGraph: {
    title: "Address Atlas",
    description: "Paste wallet addresses and scan balances across Bitcoin, EVM and Cosmos chains."
  }
};

export default function RootLayout({
  children
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
