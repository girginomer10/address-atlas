import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  getSyncRegistrationConfig: vi.fn(),
  ensureSyncSchema: vi.fn(),
  query: vi.fn()
}));

vi.mock("./config", () => ({
  getSyncRegistrationConfig: mocks.getSyncRegistrationConfig
}));

vi.mock("./postgres", () => ({
  ensureSyncSchema: mocks.ensureSyncSchema,
  getSyncPool: () => ({ query: mocks.query })
}));

import {
  assertRegistrationEnabled,
  RegistrationAdmissionQuotaError,
  RegistrationDisabledError,
  reserveRegistrationAdmission
} from "./registration";

describe("durable registration admission", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.getSyncRegistrationConfig.mockReturnValue({ enabled: true, hourlyLimit: 100 });
    mocks.ensureSyncSchema.mockResolvedValue(undefined);
    mocks.query.mockResolvedValue({ rowCount: 1, rows: [{ admission_count: 1 }] });
  });

  it("fails closed before database work when registration is disabled", async () => {
    mocks.getSyncRegistrationConfig.mockReturnValue({ enabled: false, hourlyLimit: 100 });
    expect(() => assertRegistrationEnabled()).toThrow(RegistrationDisabledError);
    await expect(reserveRegistrationAdmission()).rejects.toBeInstanceOf(RegistrationDisabledError);
    expect(mocks.ensureSyncSchema).not.toHaveBeenCalled();
    expect(mocks.query).not.toHaveBeenCalled();
  });

  it("uses one atomic PostgreSQL upsert for the cross-process hourly ceiling", async () => {
    await expect(reserveRegistrationAdmission()).resolves.toBeUndefined();
    expect(mocks.query).toHaveBeenCalledWith(
      expect.stringMatching(/INSERT INTO registration_usage[\s\S]*ON CONFLICT[\s\S]*admission_count < \$1/),
      [100]
    );
  });

  it("returns a stable capacity error when the durable window is full", async () => {
    mocks.query.mockResolvedValue({ rowCount: 0, rows: [] });
    await expect(reserveRegistrationAdmission()).rejects.toBeInstanceOf(RegistrationAdmissionQuotaError);
  });
});
