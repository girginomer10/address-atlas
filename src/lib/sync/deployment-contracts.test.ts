import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";

const repoRoot = resolve(import.meta.dirname, "../../..");
const composeFile = join(repoRoot, "server/sync/compose.prod.yml");
const syncDockerfile = join(repoRoot, "server/sync/Dockerfile");
const productionEnvExample = join(repoRoot, "server/sync/.env.production.example");
const syncReadme = join(repoRoot, "server/sync/README.md");
const developmentEnvExample = join(repoRoot, ".env.example");
const globalStyles = join(repoRoot, "src/app/globals.css");
const caddyFile = join(repoRoot, "server/sync/Caddyfile");
const releaseChecklist = join(repoRoot, "docs/RELEASE_CHECKLIST.md");
const restoreDrillUnit = join(repoRoot, "server/sync/systemd/address-atlas-restore-drill.service");

describe("static production deployment contracts", () => {
  it("derives WebAuthn origin from the published host and forwards database controls", () => {
    const compose = readFileSync(composeFile, "utf8");
    const envExample = readFileSync(productionEnvExample, "utf8");
    const developmentEnv = readFileSync(developmentEnvExample, "utf8");

    expect(compose).toContain('PASSKEY_ORIGIN: "https://\${ADDRESS_ATLAS_DOMAIN:');
    expect(compose).toContain('ADDRESS_ATLAS_DOMAIN: "\${ADDRESS_ATLAS_DOMAIN:');
    expect(compose).toContain('name: "\${ADDRESS_ATLAS_POSTGRES_VOLUME:-address-atlas-prod-postgres}"');
    expect(compose).toContain('name: "\${ADDRESS_ATLAS_CADDY_DATA_VOLUME:-address-atlas-caddy-data}"');
    expect(compose).toContain('name: "\${ADDRESS_ATLAS_CADDY_CONFIG_VOLUME:-address-atlas-caddy-config}"');
    expect(compose).toContain('NATIVE_ENDPOINT_CONFIG_VERSION: "\${NATIVE_ENDPOINT_CONFIG_VERSION:-5}"');
    expect(compose).toContain('NATIVE_ENDPOINT_CONFIG_UPDATED_AT: "\${NATIVE_ENDPOINT_CONFIG_UPDATED_AT:-2026-07-14T00:00:00.000Z}"');
    expect(compose).toContain('SYNC_SCHEMA_DATABASE_URL: "\${SYNC_SCHEMA_DATABASE_URL:');
    expect(compose).toContain('SYNC_SCHEMA_MODE: "validate"');
    expect(compose).toContain('SYNC_REGISTRATION_ENABLED: "\${SYNC_REGISTRATION_ENABLED:-false}"');
    expect(compose).toContain("SYNC_GLOBAL_VAULT_DAILY_INGRESS_BYTE_LIMIT:");
    expect(compose).toContain('command: ["node", "dist/sync-bootstrap.cjs"]');
    expect(compose).toMatch(/db-role-bootstrap:[\s\S]*?POSTGRES_PASSWORD:[\s\S]*?db-provision:/);
    const steadyProvision = compose.match(/  db-provision:[\s\S]*?\n  postgres:/)?.[0] ?? "";
    expect(steadyProvision).toContain("POSTGRES_ADMIN_PASSWORD:");
    expect(steadyProvision).not.toContain("POSTGRES_PASSWORD:");
    expect(envExample).toContain("SYNC_DATABASE_URL=postgres://address_atlas_runtime:");
    for (const setting of ["SYNC_DB_POOL_SIZE", "SYNC_DB_IDLE_TIMEOUT_MS"]) {
      expect(compose).toContain(`${setting}:`);
      expect(envExample).toMatch(new RegExp(`^${setting}=`, "m"));
      expect(developmentEnv).toMatch(new RegExp(`^${setting}=`, "m"));
    }
    expect(envExample).not.toMatch(/^PASSKEY_ORIGIN=/m);
    for (const volumeOverride of [
      "ADDRESS_ATLAS_POSTGRES_VOLUME",
      "ADDRESS_ATLAS_CADDY_DATA_VOLUME",
      "ADDRESS_ATLAS_CADDY_CONFIG_VOLUME"
    ]) {
      expect(envExample).not.toMatch(new RegExp(`^${volumeOverride}=`, "m"));
      expect(envExample).toMatch(new RegExp(`^# ${volumeOverride}=`, "m"));
    }
  });

  it("pins production base images and binds the web artifact to the Git revision", () => {
    const compose = readFileSync(composeFile, "utf8");
    const dockerfile = readFileSync(syncDockerfile, "utf8");

    expect(compose).toContain("caddy:2.11.4-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648");
    expect(compose).toContain("postgres:16.14-alpine3.24@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777");
    expect(compose).toContain('image: "address-atlas-sync:\${ADDRESS_ATLAS_BUILD_REVISION:');
    expect(compose).toContain('max-size: "10m"');
    expect(compose).toContain('max-file: "10"');
    expect(compose).toContain("read_only: true");
    expect(compose).toContain("cap_drop:\n      - ALL");
    expect(compose).toContain("/tmp:rw,noexec,nosuid,size=64m");
    expect(compose).toContain("data:\n    internal: true");
    expect(compose).toMatch(/caddy:[\s\S]*?networks:\n\s+- edge[\s\S]*?web:/);
    expect(compose).toMatch(/postgres:[\s\S]*?networks:\n\s+- data/);
    expect(dockerfile.match(/node:22\.23\.1-alpine3\.24@sha256:16e22a550f3863206a3f701448c45f7912c6896a62de43add43bb9c86130c3e2/g))
      .toHaveLength(3);
    expect(dockerfile).toContain("LABEL org.opencontainers.image.revision=${ADDRESS_ATLAS_BUILD_REVISION}");
    expect(dockerfile).toContain("dist/sync-bootstrap.cjs");
    expect(dockerfile).toContain("dist/sync-restore.cjs");
  });

  it("sandboxes the public proxy and enforces per-service resource ceilings", () => {
    const compose = readFileSync(composeFile, "utf8");
    const caddy = compose.match(/  caddy:[\s\S]*?\n  web:/)?.[0] ?? "";
    expect(caddy).toContain("read_only: true");
    expect(caddy).toContain("/tmp:rw,noexec,nosuid,size=32m");
    expect(caddy).toContain("cap_drop:\n      - ALL");
    expect(caddy).toContain("cap_add:\n      - NET_BIND_SERVICE");
    for (const service of ["caddy", "web", "schema", "db-role-bootstrap", "db-provision", "postgres"]) {
      const nextService = service === "postgres" ? "volumes:" : "  [a-z]";
      const section = compose.match(new RegExp(`  ${service}:[\\s\\S]*?\\n${nextService}`))?.[0] ?? "";
      expect(section, `${service} resource contract`).toContain("pids_limit:");
      expect(section, `${service} resource contract`).toContain("mem_limit:");
      expect(section, `${service} resource contract`).toContain("mem_reservation:");
    }
  });

  it("keeps copyable Ethereum endpoint examples on PublicNode's live root path", () => {
    for (const file of [productionEnvExample, syncReadme]) {
      const contents = readFileSync(file, "utf8");
      expect(contents).toContain("https://ethereum-rpc.publicnode.com");
      expect(contents).not.toContain("https://ethereum-rpc.publicnode.com/rpc");
    }
  });

  it("documents every required native sync route", () => {
    const contents = readFileSync(syncReadme, "utf8");
    for (const route of [
      "GET /config/native",
      "GET /healthz",
      "GET /auth/native",
      "POST /auth/passkey/options",
      "POST /auth/passkey/verify",
      "GET /vault/latest",
      "PUT /vault/latest",
      "DELETE /account/session",
      "DELETE /account"
    ]) {
      expect(contents).toContain(`\`${route}\``);
    }
  });

  it("uses the repository-root native test command in the release checklist", () => {
    const contents = readFileSync(releaseChecklist, "utf8");
    expect(contents).toContain("Run `npm run native:test` from the repository root.");
    expect(contents).not.toContain("- Run `swift test`.");
  });

  it("uses only local system font stacks", () => {
    const styles = readFileSync(globalStyles, "utf8");
    expect(styles).not.toMatch(/fonts\.googleapis\.com|fonts\.gstatic\.com/i);
    expect(styles).not.toMatch(/@import\s+url\(["']?https?:/i);
    expect(styles).toContain("system-ui");
    expect(styles).toContain("ui-monospace");
  });

  it("bounds slow request headers and bodies at the public proxy", () => {
    const caddy = readFileSync(caddyFile, "utf8");
    expect(caddy).toMatch(/timeouts\s*\{[^}]*read_body\s+60s/s);
    expect(caddy).toMatch(/timeouts\s*\{[^}]*read_header\s+10s/s);
  });

  it("emits structured access logs without exact client or auth query material", () => {
    const caddy = readFileSync(caddyFile, "utf8");
    expect(caddy).toContain("output stdout");
    expect(caddy).toContain("request>remote_ip ip_mask 16 32");
    expect(caddy).toContain("request>headers delete");
    expect(caddy).toContain("request>uri delete");
  });

  it("lets the hardened scheduled drill write only its daemon-visible recovery paths", () => {
    const unit = readFileSync(restoreDrillUnit, "utf8");
    expect(unit).toContain("PrivateTmp=true");
    expect(unit).toContain("ProtectSystem=strict");
    expect(unit).toContain("Environment=ADDRESS_ATLAS_DEPLOY_SOURCE_ROOT=/var/lib/address-atlas/deploy-sources");
    expect(unit).toMatch(/ReadWritePaths=.*\/var\/backups\/address-atlas/);
    expect(unit).toMatch(/ReadWritePaths=.*\/var\/lib\/address-atlas\/deploy-sources/);
    expect(unit).toContain("/var/run/docker.sock");
  });

  it("keeps scheduled recovery jobs writable only where Git and artifacts require it", () => {
    const backupUnit = readFileSync(
      join(repoRoot, "server/sync/systemd/address-atlas-backup.service"),
      "utf8"
    );
    const drillUnit = readFileSync(restoreDrillUnit, "utf8");
    const timer = readFileSync(
      join(repoRoot, "server/sync/systemd/address-atlas-backup.timer"),
      "utf8"
    );

    for (const unit of [backupUnit, drillUnit]) {
      expect(unit).toContain("ProtectSystem=strict");
      expect(unit).toContain("Environment=ADDRESS_ATLAS_DEPLOY_SOURCE_ROOT=/var/lib/address-atlas/deploy-sources");
      expect(unit).toMatch(/ReadWritePaths=.*\/opt\/address-atlas\/\.git/);
      expect(unit).toMatch(/ReadWritePaths=.*\/var\/backups\/address-atlas/);
      expect(unit).toMatch(/ReadWritePaths=.*\/var\/lib\/address-atlas\/deploy-sources/);
      expect(unit).toContain("/var/run/docker.sock");
    }
    expect(timer).toContain("OnCalendar=*-*-* 00,05,10,15,20:15:00 UTC");
    expect(timer).toContain("RandomizedDelaySec=15min");
  });

  it("makes three-strike paging and recovery evidence a production release gate", () => {
    const operations = readFileSync(join(repoRoot, "docs/OPERATIONS.md"), "utf8");
    const checklist = readFileSync(releaseChecklist, "utf8");

    for (const document of [operations, checklist]) {
      expect(document).toMatch(/three\s+consecutive nonzero monitor executions/i);
      expect(document).toMatch(/exactly one\s+incident/i);
      expect(document).toMatch(/exactly one\s+recovery notification/i);
      expect(document).toMatch(/event IDs or screenshots/i);
      expect(document).toMatch(/paging\s+rule version/i);
    }
  });
});
