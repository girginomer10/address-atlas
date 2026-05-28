import { NextResponse, type NextRequest } from "next/server";
import { isSyncOnlyMode, isSyncOnlyPathAllowed } from "@/lib/sync/sync-only";

export function proxy(request: NextRequest) {
  if (!isSyncOnlyMode()) {
    return NextResponse.next();
  }

  if (isSyncOnlyPathAllowed(request.nextUrl.pathname)) {
    return NextResponse.next();
  }

  return NextResponse.json({ error: "Not found." }, { status: 404 });
}

export const config = {
  // Match every path so the sync-only gate also covers dotted routes
  // (e.g. /api/foo.json); isSyncOnlyPathAllowed is the sole allowlist.
  matcher: ["/(.*)"]
};
