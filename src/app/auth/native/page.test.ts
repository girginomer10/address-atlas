import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { NativePasskeyBridge } from "./NativePasskeyBridge";
import NativeAuthPage from "./page";

const CALLBACK = "address-atlas://sync-auth";
const STATE = "11111111-1111-4111-8111-111111111111";

describe("native passkey mode binding", () => {
  it("shows only registration controls for a registration request", () => {
    const html = renderToStaticMarkup(createElement(NativePasskeyBridge, {
      callback: CALLBACK,
      state: STATE,
      mode: "register"
    }));
    expect(html).toContain("Create passkey");
    expect(html).toContain("Account label");
    expect(html).not.toContain(">Sign in<");
  });

  it("shows only sign-in controls for an authentication request", () => {
    const html = renderToStaticMarkup(createElement(NativePasskeyBridge, {
      callback: CALLBACK,
      state: STATE,
      mode: "authenticate"
    }));
    expect(html).toContain("Sign in");
    expect(html).not.toContain("Create passkey");
    expect(html).not.toContain("Account label");
  });

  it("rejects missing/invalid mode and callback authority", async () => {
    const page = await NativeAuthPage({
      searchParams: Promise.resolve({ mode: "delete", callback: CALLBACK, state: STATE })
    });
    const bridge = page.props.children;
    expect(bridge.props.mode).toBeNull();

    const html = renderToStaticMarkup(createElement(NativePasskeyBridge, {
      callback: "address-atlas://attacker",
      state: STATE,
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
        state: [STATE, STATE]
      })
    });
    const bridge = page.props.children;

    expect(bridge.props.mode).toBeNull();
    expect(bridge.props.callback).toBe("");
    expect(bridge.props.state).toBe("");
  });
});
