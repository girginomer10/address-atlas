import { Suspense } from "react";
import { NativePasskeyBridge } from "./NativePasskeyBridge";

export const dynamic = "force-dynamic";

export default async function NativeAuthPage({
  searchParams
}: {
  searchParams: Promise<{
    callback?: string | string[];
    state?: string | string[];
    mode?: string | string[];
  }>;
}) {
  const params = await searchParams;
  const callback = typeof params.callback === "string" ? params.callback : "";
  const state = typeof params.state === "string" ? params.state : "";
  const mode = params.mode === "register" || params.mode === "authenticate" ? params.mode : null;
  return (
    <Suspense>
      <NativePasskeyBridge callback={callback} state={state} mode={mode} />
    </Suspense>
  );
}
