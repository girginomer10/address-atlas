import { Suspense } from "react";
import { NativePasskeyBridge } from "./NativePasskeyBridge";

export const dynamic = "force-dynamic";

export default async function NativeAuthPage({
  searchParams
}: {
  searchParams: Promise<{ callback?: string; state?: string; mode?: string }>;
}) {
  const params = await searchParams;
  const mode = params.mode === "register" || params.mode === "authenticate" ? params.mode : null;
  return (
    <Suspense>
      <NativePasskeyBridge callback={params.callback || ""} state={params.state || ""} mode={mode} />
    </Suspense>
  );
}
