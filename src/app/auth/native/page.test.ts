import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { NativePasskeyBridge } from "./NativePasskeyBridge";
import NativeAuthPage from "./page";

const CALLBACK = "address-atlas://sync-auth";
const STATE = "11111111-1111-4111-8111-111111111111";
const CODE_CHALLENGE = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

describe("native passkey mode binding", () => {
  it("shows only registration controls for a registration request", () => {
    const html = renderToStaticMarkup(createElement(NativePasskeyBridge, {
      callback: CALLBACK,
      state: STATE,
      codeChallenge: CODE_CHALLENGE,
      codeChallengeMethod: "S256",
      mode: "register"
    }));
    expect(html).toContain("Create passkey");
    expect(html).toContain("Account label");
    expect(html).toContain('autoComplete="nickname"');
    expect(html).toContain("stores opaque encrypted snapshots with limited sync metadata");
    expect(html).toContain("never receives vault plaintext or key material");
    expect(html).not.toContain("server receives account auth only");
    expect(html).not.toContain("<form");
    expect(html).toContain('aria-busy="false"');
    expect(html).toContain('aria-labelledby="passkey-heading"');
    expect(html).toContain('type="button"');
    expect(html).not.toContain('type="submit"');
    expect(html).not.toContain(">Sign in<");
  });

  it("shows only sign-in controls for an authentication request", () => {
    const html = renderToStaticMarkup(createElement(NativePasskeyBridge, {
      callback: CALLBACK,
      state: STATE,
      codeChallenge: CODE_CHALLENGE,
      codeChallengeMethod: "S256",
      mode: "authenticate"
    }));
    expect(html).toContain("Sign in");
    expect(html).not.toContain("Create passkey");
    expect(html).not.toContain("Account label");
  });

  it("rejects missing/invalid mode and callback authority", async () => {
    const page = await NativeAuthPage({
      searchParams: Promise.resolve({
        mode: "delete",
        callback: CALLBACK,
        state: STATE,
        code_challenge: CODE_CHALLENGE,
        code_challenge_method: "S256"
      })
    });
    const bridge = page.props.children;
    expect(bridge.props.mode).toBeNull();

    const invalidModeHTML = renderToStaticMarkup(createElement(NativePasskeyBridge, {
      callback: CALLBACK,
      state: STATE,
      codeChallenge: CODE_CHALLENGE,
      codeChallengeMethod: "S256",
      mode: null
    }));
    expect(invalidModeHTML).toContain('role="alert"');
    expect(invalidModeHTML).toContain('aria-live="assertive"');
    expect(invalidModeHTML).toContain('aria-atomic="true"');
    expect(invalidModeHTML).toContain('aria-describedby="passkey-status"');

    const html = renderToStaticMarkup(createElement(NativePasskeyBridge, {
      callback: "address-atlas://attacker",
      state: STATE,
      codeChallenge: CODE_CHALLENGE,
      codeChallengeMethod: "S256",
      mode: "authenticate"
    }));
    expect(html).toContain("disabled");
    expect(html).toContain("Open this page from Address Atlas Mac.");
  });

  it.each([
    "address-atlas://user@sync-auth",
    "address-atlas://sync-auth:443",
    "address-atlas://sync-auth/extra",
    "address-atlas://sync-auth?unexpected=value",
    "address-atlas://sync-auth#fragment"
  ])("rejects callback components the native parser cannot accept: %s", (callback) => {
    const html = renderToStaticMarkup(createElement(NativePasskeyBridge, {
      callback,
      state: STATE,
      codeChallenge: CODE_CHALLENGE,
      codeChallengeMethod: "S256",
      mode: "authenticate"
    }));

    expect(html).toContain("disabled");
    expect(html).toContain("Open this page from Address Atlas Mac.");
  });

  it("rejects duplicated security parameters instead of coercing an array", async () => {
    const page = await NativeAuthPage({
      searchParams: Promise.resolve({
        mode: ["authenticate", "register"],
        callback: [CALLBACK, "address-atlas://attacker"],
        state: [STATE, STATE],
        code_challenge: [CODE_CHALLENGE, CODE_CHALLENGE],
        code_challenge_method: ["S256", "plain"]
      })
    });
    const bridge = page.props.children;

    expect(bridge.props.mode).toBeNull();
    expect(bridge.props.callback).toBe("");
    expect(bridge.props.state).toBe("");
    expect(bridge.props.codeChallenge).toBe("");
    expect(bridge.props.codeChallengeMethod).toBe("");
  });

  it.each([
    ["", "S256"],
    ["not-canonical", "S256"],
    [CODE_CHALLENGE, "plain"]
  ])("rejects an invalid PKCE binding: %s / %s", (codeChallenge, codeChallengeMethod) => {
    const html = renderToStaticMarkup(createElement(NativePasskeyBridge, {
      callback: CALLBACK,
      state: STATE,
      codeChallenge,
      codeChallengeMethod,
      mode: "authenticate"
    }));

    expect(html).toContain("disabled");
    expect(html).toContain("Open this page from Address Atlas Mac.");
  });
});
