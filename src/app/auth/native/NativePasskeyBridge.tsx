"use client";

import { startAuthentication, startRegistration } from "@simplewebauthn/browser";
import type {
  PublicKeyCredentialCreationOptionsJSON,
  PublicKeyCredentialRequestOptionsJSON
} from "@simplewebauthn/browser";
import { useMemo, useState } from "react";

type Mode = "register" | "authenticate";

type OptionsResponse = {
  mode: Mode;
  challengeToken: string;
  publicKey: PublicKeyCredentialCreationOptionsJSON | PublicKeyCredentialRequestOptionsJSON;
  error?: string;
};

type VerifyResponse = {
  verified?: boolean;
  userId?: string;
  sessionToken?: string;
  error?: string;
};

export function NativePasskeyBridge({ callback }: { callback: string }) {
  const [accountName, setAccountName] = useState("");
  const [busy, setBusy] = useState<Mode | null>(null);
  const [message, setMessage] = useState("");
  const canReturn = useMemo(() => callback.startsWith("address-atlas://"), [callback]);

  async function run(mode: Mode) {
    setBusy(mode);
    setMessage("");
    try {
      if (!canReturn) {
        throw new Error("Native return URL is missing.");
      }
      const optionsResponse = await fetch("/auth/passkey/options", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          mode,
          accountName: accountName.trim() || undefined
        })
      });
      const options = (await optionsResponse.json()) as OptionsResponse;
      if (!optionsResponse.ok || options.error) {
        throw new Error(options.error || "Passkey options failed.");
      }

      const response =
        mode === "register"
          ? await startRegistration({
              optionsJSON: options.publicKey as PublicKeyCredentialCreationOptionsJSON
            })
          : await startAuthentication({
              optionsJSON: options.publicKey as PublicKeyCredentialRequestOptionsJSON
            });

      const verifyResponse = await fetch("/auth/passkey/verify", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          mode,
          challengeToken: options.challengeToken,
          response
        })
      });
      const verified = (await verifyResponse.json()) as VerifyResponse;
      if (!verifyResponse.ok || !verified.verified || !verified.sessionToken || !verified.userId) {
        throw new Error(verified.error || "Passkey verification failed.");
      }

      const returnURL = new URL(callback);
      returnURL.searchParams.set("sessionToken", verified.sessionToken);
      returnURL.searchParams.set("userId", verified.userId);
      returnURL.searchParams.set("serverURL", window.location.origin);
      window.location.assign(returnURL.toString());
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Passkey flow failed.");
    } finally {
      setBusy(null);
    }
  }

  return (
    <main className="aa-auth-bridge">
      <section className="aa-auth-panel">
        <div>
          <span className="aa-eyebrow">Address Atlas Mac</span>
          <h1>Passkey Sync</h1>
          <p>
            Connect the Mac app to encrypted vault sync. The server receives account auth only; vault
            contents stay encrypted before upload.
          </p>
        </div>

        <label>
          Account label
          <input
            value={accountName}
            onChange={(event) => setAccountName(event.target.value)}
            placeholder="Omer's Mac"
            autoComplete="username webauthn"
          />
        </label>

        <div className="aa-auth-actions">
          <button type="button" onClick={() => run("register")} disabled={Boolean(busy)}>
            {busy === "register" ? "Creating..." : "Create passkey"}
          </button>
          <button type="button" onClick={() => run("authenticate")} disabled={Boolean(busy)}>
            {busy === "authenticate" ? "Signing in..." : "Sign in"}
          </button>
        </div>

        {message ? <p className="aa-auth-error">{message}</p> : null}
        {!canReturn ? <p className="aa-auth-error">Open this page from Address Atlas Mac.</p> : null}
      </section>
    </main>
  );
}
