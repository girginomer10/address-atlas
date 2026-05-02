import { NextRequest, NextResponse } from "next/server";
import { getPreferences, PreferenceRecord, updatePreferences } from "@/lib/local-store";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET() {
  try {
    return NextResponse.json(await getPreferences());
  } catch (error) {
    return errorResponse(error, "Preferences could not be loaded.");
  }
}

export async function PATCH(request: NextRequest) {
  try {
    const body = (await request.json()) as Partial<PreferenceRecord>;
    return NextResponse.json(await updatePreferences(sanitize(body)));
  } catch (error) {
    return errorResponse(error, "Preferences could not be saved.");
  }
}

function sanitize(input: Partial<PreferenceRecord>) {
  return Object.fromEntries(Object.entries({
    darkMode: typeof input.darkMode === "boolean" ? input.darkMode : undefined,
    density: input.density === "compact" || input.density === "comfy" ? input.density : undefined,
    mono: typeof input.mono === "boolean" ? input.mono : undefined,
    hideDust: typeof input.hideDust === "boolean" ? input.hideDust : undefined,
    dustThreshold: Number.isFinite(input.dustThreshold) ? Number(input.dustThreshold) : undefined,
    autoRefresh: typeof input.autoRefresh === "boolean" ? input.autoRefresh : undefined,
    currency: typeof input.currency === "string" ? input.currency : undefined
  }).filter(([, value]) => value !== undefined)) as Partial<PreferenceRecord>;
}

function errorResponse(error: unknown, fallback: string) {
  return NextResponse.json(
    {
      error: fallback,
      details: error instanceof Error ? error.message : "Unknown error"
    },
    { status: 500 }
  );
}
