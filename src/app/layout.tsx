import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Address Atlas Sync",
  description: "Encrypted sync server for the Address Atlas native macOS app.",
  robots: { index: false, follow: false },
  openGraph: {
    title: "Address Atlas Sync",
    description: "Encrypted, zero-knowledge vault sync for the Address Atlas Mac app."
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
