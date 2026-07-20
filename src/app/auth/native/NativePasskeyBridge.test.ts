import { describe, expect, it, vi } from "vitest";
import { runPasskeyCeremony } from "./NativePasskeyBridge";

const CALLBACK = "address-atlas://sync-auth";
const STATE = "11111111-1111-4111-8111-111111111111";
const ORIGIN = "https://sync.example.com";
const USER_ID = "22222222-2222-4222-8222-222222222222";

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" }
  });
}

function fetchStub(handlers: { options?: () => Response; verify?: () => Response }) {
  return vi.fn(async (input: string, init?: RequestInit) => {
    void init;
    if (input === "/auth/passkey/options" && handlers.options) return handlers.options();
    if (input === "/auth/passkey/verify" && handlers.verify) return handlers.verify();
    throw new Error(`Unexpected fetch: ${input}`);
  });
}

function sentJSON(fetchImpl: ReturnType<typeof fetchStub>, call: number) {
  return JSON.parse(fetchImpl.mock.calls[call]![1]!.body as string);
}

describe("native passkey ceremony", () => {
  it("runs the full registration ceremony and returns to the native app", async () => {
    const publicKey = { challenge: "registration-challenge", rp: { id: "localhost" } };
    const credential = { id: "credential-1", type: "public-key" };
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "register", challengeToken: "challenge-token-1", publicKey }),
      verify: () => jsonResponse({ verified: true, userId: USER_ID, sessionToken: "session-token-1" })
    });
    const startRegistrationImpl = vi.fn(async () => credential);
    const startAuthenticationImpl = vi.fn(async () => ({}));
    const navigate = vi.fn();

    await runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, accountName: "  Omer's Mac  ", canReturn: true },
      { fetchImpl, startRegistrationImpl, startAuthenticationImpl, locationOrigin: ORIGIN, navigate }
    );

    expect(fetchImpl).toHaveBeenNthCalledWith(1, "/auth/passkey/options", expect.objectContaining({
      method: "POST",
      headers: { "content-type": "application/json" }
    }));
    expect(sentJSON(fetchImpl, 0)).toEqual({ mode: "register", accountName: "Omer's Mac" });
    expect(startRegistrationImpl).toHaveBeenCalledExactlyOnceWith({ optionsJSON: publicKey });
    expect(startAuthenticationImpl).not.toHaveBeenCalled();
    expect(sentJSON(fetchImpl, 1)).toEqual({
      mode: "register",
      challengeToken: "challenge-token-1",
      response: credential
    });

    expect(navigate).toHaveBeenCalledOnce();
    const target = new URL(navigate.mock.calls[0]![0] as string);
    expect(target.protocol).toBe("address-atlas:");
    expect(target.hostname).toBe("sync-auth");
    expect(target.searchParams.get("sessionToken")).toBe("session-token-1");
    expect(target.searchParams.get("userId")).toBe(USER_ID);
    expect(target.searchParams.get("serverURL")).toBe(ORIGIN);
    expect(target.searchParams.get("state")).toBe(STATE);
  });

  it("runs the authentication ceremony without sending an account name", async () => {
    const publicKey = { challenge: "authentication-challenge", rpId: "localhost" };
    const assertion = { id: "credential-2", type: "public-key" };
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "authenticate", challengeToken: "challenge-token-2", publicKey }),
      verify: () => jsonResponse({ verified: true, userId: USER_ID, sessionToken: "session-token-2" })
    });
    const startRegistrationImpl = vi.fn(async () => ({}));
    const startAuthenticationImpl = vi.fn(async () => assertion);
    const navigate = vi.fn();

    await runPasskeyCeremony(
      { mode: "authenticate", callback: CALLBACK, state: STATE, accountName: "", canReturn: true },
      { fetchImpl, startRegistrationImpl, startAuthenticationImpl, locationOrigin: ORIGIN, navigate }
    );

    expect(sentJSON(fetchImpl, 0)).toEqual({ mode: "authenticate" });
    expect(startAuthenticationImpl).toHaveBeenCalledExactlyOnceWith({ optionsJSON: publicKey });
    expect(startRegistrationImpl).not.toHaveBeenCalled();
    expect(sentJSON(fetchImpl, 1)).toEqual({
      mode: "authenticate",
      challengeToken: "challenge-token-2",
      response: assertion
    });
    const target = new URL(navigate.mock.calls[0]![0] as string);
    expect(target.searchParams.get("sessionToken")).toBe("session-token-2");
    expect(target.searchParams.get("serverURL")).toBe(ORIGIN);
  });

  it("refuses to start without a valid native return URL", async () => {
    const fetchImpl = fetchStub({});
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "register", callback: "address-atlas://attacker", state: STATE, accountName: "", canReturn: false },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => ({})),
        startAuthenticationImpl: vi.fn(async () => ({})),
        locationOrigin: ORIGIN,
        navigate
      }
    )).rejects.toThrow("Native return URL is missing.");

    expect(fetchImpl).not.toHaveBeenCalled();
    expect(navigate).not.toHaveBeenCalled();
  });

  it("surfaces the server error from a failed options request before any ceremony", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ error: "Too many requests." }, 429)
    });
    const startRegistrationImpl = vi.fn(async () => ({}));
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl,
        startAuthenticationImpl: vi.fn(async () => ({})),
        locationOrigin: ORIGIN,
        navigate
      }
    )).rejects.toThrow("Too many requests.");

    expect(startRegistrationImpl).not.toHaveBeenCalled();
    expect(navigate).not.toHaveBeenCalled();
  });

  it("surfaces a failed verification and never returns to the native app", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "authenticate", challengeToken: "challenge-token-3", publicKey: {} }),
      verify: () => jsonResponse({ verified: false, error: "Passkey verification failed." }, 400)
    });
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "authenticate", callback: CALLBACK, state: STATE, accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => ({})),
        startAuthenticationImpl: vi.fn(async () => ({ id: "credential-3" })),
        locationOrigin: ORIGIN,
        navigate
      }
    )).rejects.toThrow("Passkey verification failed.");

    expect(navigate).not.toHaveBeenCalled();
  });

  it("treats an ok verification without a session token as a failure", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "authenticate", challengeToken: "challenge-token-4", publicKey: {} }),
      verify: () => jsonResponse({ verified: true, userId: USER_ID })
    });
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "authenticate", callback: CALLBACK, state: STATE, accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => ({})),
        startAuthenticationImpl: vi.fn(async () => ({ id: "credential-4" })),
        locationOrigin: ORIGIN,
        navigate
      }
    )).rejects.toThrow("Passkey verification failed.");

    expect(navigate).not.toHaveBeenCalled();
  });

  it("propagates an authenticator ceremony failure without calling verify", async () => {
    const fetchImpl = fetchStub({
      options: () => jsonResponse({ mode: "register", challengeToken: "challenge-token-5", publicKey: {} })
    });
    const navigate = vi.fn();

    await expect(runPasskeyCeremony(
      { mode: "register", callback: CALLBACK, state: STATE, accountName: "", canReturn: true },
      {
        fetchImpl,
        startRegistrationImpl: vi.fn(async () => {
          throw new Error("The operation either timed out or was not allowed.");
        }),
        startAuthenticationImpl: vi.fn(async () => ({})),
        locationOrigin: ORIGIN,
        navigate
      }
    )).rejects.toThrow("The operation either timed out or was not allowed.");

    expect(fetchImpl).toHaveBeenCalledExactlyOnceWith("/auth/passkey/options", expect.anything());
    expect(navigate).not.toHaveBeenCalled();
  });
});
