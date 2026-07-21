#!/usr/bin/env node

import { createHash, randomUUID } from "node:crypto";
import {
  closeSync,
  constants,
  existsSync,
  fsyncSync,
  lstatSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  unlinkSync,
  writeFileSync
} from "node:fs";
import { basename, dirname, isAbsolute, join, parse, resolve, sep } from "node:path";

const MINIMUM_CONFIG_VERSION = 5;
const MAXIMUM_CONFIG_VERSION = 2_000_000_000;
const MAXIMUM_INPUT_BYTES = 1_000_000;
// Operators and GitHub runners can differ slightly, but a policy timestamp is
// evidence of an already-authored policy, not a scheduler. Five minutes keeps
// ordinary clock skew safe without letting a typo create a years-long high-water.
const MAXIMUM_FUTURE_SKEW_MS = 5 * 60 * 1_000;
const STATE_KEYS = [
  "schemaVersion",
  "version",
  "digest",
  "updatedAtEpochMs",
  "revision",
  "imageId"
];
const INSTALL_STATE_KEYS = ["schemaVersion", "phase", "revision", "imageId", "postgresVolume"];
const INSTALL_PHASES = ["candidate-ready", "schema-ready", "roles-ready"];
const CONFIG_KEYS = new Set([
  "schemaVersion",
  "configVersion",
  "updatedAt",
  "refreshAfterSeconds",
  "minSupportedAppVersion",
  "message",
  "priceBaseUrl",
  "chains",
  "exchanges"
]);
const ENDPOINT_KEYS = new Set(["rpcUrl", "restUrl", "explorerUrl"]);
const BUNDLED_PRICE_URL = "https://api.coingecko.com/api/v3/simple/price";
const BUNDLED_CHAIN_ENDPOINTS = Object.freeze({
  bitcoin: { restUrl: "https://blockstream.info/api" },
  solana: { rpcUrl: "https://api.mainnet-beta.solana.com" },
  tron: { restUrl: "https://api.trongrid.io" },
  xrp: { rpcUrl: "https://s1.ripple.com:51234/" },
  ethereum: { rpcUrl: "https://ethereum-rpc.publicnode.com" },
  base: { rpcUrl: "https://mainnet.base.org" },
  arbitrum: { rpcUrl: "https://arb1.arbitrum.io/rpc" },
  optimism: { rpcUrl: "https://mainnet.optimism.io" },
  polygon: { rpcUrl: "https://polygon.drpc.org" },
  bsc: { rpcUrl: "https://bsc-dataseed.binance.org" },
  avalanche: { rpcUrl: "https://api.avax.network/ext/bc/C/rpc" },
  gnosis: { rpcUrl: "https://rpc.gnosischain.com" },
  linea: { rpcUrl: "https://rpc.linea.build" },
  mantle: { rpcUrl: "https://rpc.mantle.xyz" },
  scroll: { rpcUrl: "https://rpc.scroll.io" },
  "zksync-era": { rpcUrl: "https://mainnet.era.zksync.io" },
  cosmoshub: { restUrl: "https://cosmos-api.polkachu.com" },
  osmosis: { restUrl: "https://lcd.osmosis.zone" },
  celestia: { restUrl: "https://celestia-api.polkachu.com" },
  stride: { restUrl: "https://stride-api.polkachu.com" }
});

class StateError extends Error {
  constructor(message, status = 65) {
    super(message);
    this.status = status;
  }
}

function usage() {
  throw new StateError(
    "Usage: native-config-deploy-state.mjs {fingerprint|release-gate <app-version> <bundled-config-version>|verify-response <headers-file> <digest> <revision>|validate <absolute-file>|read <absolute-file>|write <absolute-file> <version> <digest> <updated-at-epoch-ms> <revision> <image-id>|install-read <absolute-file>|install-write <absolute-file> <phase> <revision> <image-id> <postgres-volume>|install-delete <absolute-file> <revision> <image-id> <postgres-volume>}",
    64
  );
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function boundedInteger(value, minimum, maximum) {
  return Number.isSafeInteger(value) && value >= minimum && value <= maximum;
}

function validateConfig(value) {
  if (!isPlainObject(value)) throw new StateError("Native config must be a JSON object.");
  if (Object.keys(value).some((key) => !CONFIG_KEYS.has(key))) {
    throw new StateError("Native config contains an unknown field.");
  }
  if (value.schemaVersion !== 1) throw new StateError("Native config schema is unsupported.");
  if (!boundedInteger(value.configVersion, MINIMUM_CONFIG_VERSION, MAXIMUM_CONFIG_VERSION)) {
    throw new StateError("Native config version is invalid.");
  }
  if (!isExactUtcTimestamp(value.updatedAt)) {
    throw new StateError("Native config timestamp is invalid.");
  }
  if (!timestampIsWithinFutureSkew(Date.parse(value.updatedAt))) {
    throw new StateError("Native config timestamp is implausibly in the future.");
  }
  if (!boundedInteger(value.refreshAfterSeconds, 300, 86_400)) {
    throw new StateError("Native config refresh interval is invalid.");
  }
  if (
    value.minSupportedAppVersion !== undefined
    && (
      typeof value.minSupportedAppVersion !== "string"
      || !appVersionComponents(value.minSupportedAppVersion)
    )
  ) {
    throw new StateError("Native config minimum app version is invalid.");
  }
  if (value.message !== undefined && (typeof value.message !== "string" || value.message.length > 500)) {
    throw new StateError("Native config message is invalid.");
  }
  if (!isAllowedEndpoint(value.priceBaseUrl, BUNDLED_PRICE_URL, true)) {
    throw new StateError("Native config price endpoint is invalid.");
  }
  if (!isPlainObject(value.chains)) {
    throw new StateError("Native config chains are invalid.");
  }
  for (const [chainId, endpoint] of Object.entries(value.chains)) {
    const bundled = BUNDLED_CHAIN_ENDPOINTS[chainId];
    if (
      !bundled
      ||
      !isPlainObject(endpoint)
      || Object.keys(endpoint).length === 0
      || Object.keys(endpoint).some((key) => !ENDPOINT_KEYS.has(key))
    ) {
      throw new StateError("Native config chain endpoint is invalid.");
    }
    for (const [field, candidate] of Object.entries(endpoint)) {
      const allowed = bundled[field];
      if (!allowed || !isAllowedEndpoint(candidate, allowed, false)) {
        throw new StateError("Native config chain endpoint value is invalid.");
      }
    }
  }
  if (!isPlainObject(value.exchanges) || Object.keys(value.exchanges).length !== 0) {
    throw new StateError("Native config exchange policy is invalid.");
  }
  return value;
}

function isExactUtcTimestamp(value) {
  if (typeof value !== "string") return false;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?Z$/.exec(value);
  if (!match) return false;
  const parsed = new Date(value);
  return Number.isFinite(parsed.getTime())
    && parsed.getUTCFullYear() === Number(match[1])
    && parsed.getUTCMonth() + 1 === Number(match[2])
    && parsed.getUTCDate() === Number(match[3])
    && parsed.getUTCHours() === Number(match[4])
    && parsed.getUTCMinutes() === Number(match[5])
    && parsed.getUTCSeconds() === Number(match[6]);
}

function timestampIsWithinFutureSkew(epochMs) {
  return Number.isSafeInteger(epochMs)
    && epochMs >= 0
    && epochMs <= Date.now() + MAXIMUM_FUTURE_SKEW_MS;
}

function isAllowedEndpoint(value, bundledValue, exactPath) {
  if (typeof value !== "string" || value.length > 2_048) return false;
  try {
    const url = new URL(value);
    const bundled = new URL(bundledValue);
    const effectivePort = (candidate) => candidate.port || (candidate.protocol === "https:" ? "443" : "");
    const normalizedPath = (candidate) => {
      const path = candidate.pathname || "/";
      return path.length > 1 && path.endsWith("/") ? path.slice(0, -1) : path;
    };
    return url.protocol === "https:"
      && url.hostname.length > 0
      && url.hostname.toLowerCase() === bundled.hostname.toLowerCase()
      && effectivePort(url) === effectivePort(bundled)
      && url.username === ""
      && url.password === ""
      && url.search === ""
      && url.hash === ""
      && (!exactPath || normalizedPath(url) === normalizedPath(bundled));
  } catch {
    return false;
  }
}

function appVersionComponents(value) {
  if (typeof value !== "string" || value !== value.trim()) return null;
  const parts = value.split(".");
  if (parts.length < 2 || parts.length > 4) return null;
  const parsed = [];
  for (const part of parts) {
    if (!/^\d{1,10}$/.test(part)) return null;
    const component = Number(part);
    if (!boundedInteger(component, 0, 2_000_000_000)) return null;
    parsed.push(component);
  }
  return parsed;
}

function compareAppVersions(left, right) {
  const a = appVersionComponents(left);
  const b = appVersionComponents(right);
  if (!a || !b) throw new StateError("Release app version is invalid.");
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
    const x = a[index] ?? 0;
    const y = b[index] ?? 0;
    if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
}

function verifyResponseHeaders(file, expectedDigest, expectedRevision) {
  if (
    typeof file !== "string"
    || !isAbsolute(file)
    || resolve(file) !== file
    || !/^[0-9a-f]{64}$/.test(expectedDigest)
    || !/^[0-9a-f]{40}$/.test(expectedRevision)
  ) {
    throw new StateError("Native-config response receipt arguments are invalid.");
  }
  let metadata;
  let parentMetadata;
  try {
    metadata = lstatSync(file);
    parentMetadata = lstatSync(dirname(file));
  } catch {
    throw new StateError("Native-config response headers are unavailable.", 66);
  }
  if (
    !metadata.isFile()
    || metadata.isSymbolicLink()
    || metadata.uid !== process.getuid()
    || metadata.nlink !== 1
    || (metadata.mode & 0o022) !== 0
    || metadata.size > 65_536
    || !parentMetadata.isDirectory()
    || parentMetadata.isSymbolicLink()
    || parentMetadata.uid !== process.getuid()
    || (parentMetadata.mode & 0o077) !== 0
  ) {
    throw new StateError("Native-config response header metadata is unsafe.", 66);
  }
  const lines = readFileSync(file, "utf8").split(/\r?\n/);
  const values = (name) => lines
    .map((line) => {
      const separator = line.indexOf(":");
      if (separator < 1 || line.slice(0, separator).toLowerCase() !== name) return null;
      return line.slice(separator + 1).trim();
    })
    .filter((value) => value !== null);
  const revisions = values("x-address-atlas-build-revision");
  const etags = values("etag");
  const cacheControls = values("cache-control");
  const contentTypes = values("content-type");
  if (
    revisions.length !== 1
    || revisions[0] !== expectedRevision
    || etags.length !== 1
    || etags[0] !== `"sha256-${expectedDigest}"`
    || cacheControls.length !== 1
    || !cacheControls[0].toLowerCase().split(",").map((value) => value.trim()).includes("no-store")
    || contentTypes.length !== 1
    || !/^application\/json(?:;|$)/i.test(contentTypes[0])
  ) {
    throw new StateError("Native-config response receipt does not match its body and serving revision.", 67);
  }
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (!isPlainObject(value)) return value;
  return Object.fromEntries(
    Object.keys(value).sort().map((key) => [key, canonicalize(value[key])])
  );
}

function fingerprint(value) {
  const canonical = JSON.stringify(canonicalize(validateConfig(value)));
  return {
    version: value.configVersion,
    digest: createHash("sha256").update(canonical, "utf8").digest("hex"),
    updatedAtEpochMs: Date.parse(value.updatedAt)
  };
}

function validateStatePath(file) {
  if (
    typeof file !== "string"
    || !isAbsolute(file)
    || file === parse(file).root
    || file.includes("\0")
    || file.includes("\n")
    || basename(file) === "."
    || basename(file) === ".."
  ) {
    throw new StateError("Deployment state path must be a safe absolute file path.");
  }
  const normalized = resolve(file);
  if (normalized !== file) throw new StateError("Deployment state path must be normalized.");
  const parent = dirname(file);
  const root = parse(parent).root;
  let current = root;
  for (const component of parent.slice(root.length).split(sep).filter(Boolean)) {
    current = join(current, component);
    let metadata;
    try {
      metadata = lstatSync(current);
    } catch {
      throw new StateError("Deployment state parent directory does not exist.", 66);
    }
    if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
      throw new StateError("Deployment state path contains a non-directory or symbolic link.", 66);
    }
    const writableByOthers = (metadata.mode & 0o022) !== 0;
    const trustedStickyAncestor = metadata.uid === 0
      && (metadata.mode & 0o1000) !== 0
      && (metadata.mode & 0o002) !== 0;
    if (writableByOthers && !trustedStickyAncestor) {
      throw new StateError("Deployment state path contains a group/other-writable directory.", 66);
    }
  }
  const parentMetadata = lstatSync(parent);
  if (parentMetadata.uid !== process.getuid() || (parentMetadata.mode & 0o077) !== 0) {
    throw new StateError("Deployment state parent must be owner-owned and private.", 66);
  }
  if (realpathSync(parent) !== parent) {
    throw new StateError("Deployment state parent must have a canonical path.", 66);
  }
  return { file, parent };
}

function canonicalState(state) {
  return `${JSON.stringify(state, null, 2)}\n`;
}

function validateState(value) {
  if (!isPlainObject(value) || Object.keys(value).sort().join("|") !== [...STATE_KEYS].sort().join("|")) {
    throw new StateError("Deployment state has an invalid shape.", 66);
  }
  if (
    value.schemaVersion !== 1
    || !boundedInteger(value.version, MINIMUM_CONFIG_VERSION, MAXIMUM_CONFIG_VERSION)
    || typeof value.digest !== "string"
    || !/^[0-9a-f]{64}$/.test(value.digest)
    || !boundedInteger(value.updatedAtEpochMs, 0, 8_640_000_000_000_000)
    || typeof value.revision !== "string"
    || !/^[0-9a-f]{40}$/.test(value.revision)
    || typeof value.imageId !== "string"
    || !/^sha256:[0-9a-f]{64}$/.test(value.imageId)
  ) {
    throw new StateError("Deployment state is invalid.", 66);
  }
  if (!timestampIsWithinFutureSkew(value.updatedAtEpochMs)) {
    throw new StateError("Deployment state timestamp is implausibly in the future.", 66);
  }
  return value;
}

function readState(file) {
  validateStatePath(file);
  if (!existsSync(file)) throw new StateError("Deployment state does not exist.", 66);
  const metadata = lstatSync(file);
  if (
    !metadata.isFile()
    || metadata.isSymbolicLink()
    || metadata.uid !== process.getuid()
    || metadata.nlink !== 1
    || (metadata.mode & 0o077) !== 0
    || metadata.size > 4_096
  ) {
    throw new StateError("Deployment state file metadata is unsafe.", 66);
  }
  const raw = readFileSync(file, "utf8");
  let state;
  try {
    state = validateState(JSON.parse(raw));
  } catch (error) {
    if (error instanceof StateError) throw error;
    throw new StateError("Deployment state is not valid JSON.", 66);
  }
  if (raw !== canonicalState(state)) throw new StateError("Deployment state is not canonical.", 66);
  return state;
}

function writeState(file, versionRaw, digest, updatedAtEpochMsRaw, revision, imageId) {
  const { parent } = validateStatePath(file);
  const version = Number(versionRaw);
  const updatedAtEpochMs = Number(updatedAtEpochMsRaw);
  const state = validateState({
    schemaVersion: 1,
    version,
    digest,
    updatedAtEpochMs,
    revision,
    imageId
  });
  if (existsSync(file)) readState(file);
  const temporary = join(parent, `.${basename(file)}.${randomUUID()}.tmp`);
  let descriptor;
  try {
    descriptor = openSync(
      temporary,
      constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
      0o600
    );
    writeFileSync(descriptor, canonicalState(state), { encoding: "utf8" });
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    renameSync(temporary, file);
    const directoryDescriptor = openSync(parent, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      fsyncSync(directoryDescriptor);
    } finally {
      closeSync(directoryDescriptor);
    }
  } catch (error) {
    if (descriptor !== undefined) closeSync(descriptor);
    try { unlinkSync(temporary); } catch {}
    if (error instanceof StateError) throw error;
    throw new StateError("Deployment state could not be written atomically.", 74);
  }
  return state;
}

function validateInstallState(value) {
  if (
    !isPlainObject(value)
    || Object.keys(value).sort().join("|") !== [...INSTALL_STATE_KEYS].sort().join("|")
    || value.schemaVersion !== 1
    || typeof value.phase !== "string"
    || !INSTALL_PHASES.includes(value.phase)
    || typeof value.revision !== "string"
    || !/^[0-9a-f]{40}$/.test(value.revision)
    || typeof value.imageId !== "string"
    || !/^sha256:[0-9a-f]{64}$/.test(value.imageId)
    || typeof value.postgresVolume !== "string"
    || !/^[A-Za-z0-9][A-Za-z0-9_.-]+$/.test(value.postgresVolume)
  ) {
    throw new StateError("Install deployment state is invalid.", 66);
  }
  return value;
}

function readInstallState(file) {
  validateStatePath(file);
  if (!existsSync(file)) throw new StateError("Install deployment state does not exist.", 66);
  const metadata = lstatSync(file);
  if (
    !metadata.isFile()
    || metadata.isSymbolicLink()
    || metadata.uid !== process.getuid()
    || metadata.nlink !== 1
    || (metadata.mode & 0o077) !== 0
    || metadata.size > 4_096
  ) {
    throw new StateError("Install deployment state file metadata is unsafe.", 66);
  }
  const raw = readFileSync(file, "utf8");
  let state;
  try {
    state = validateInstallState(JSON.parse(raw));
  } catch (error) {
    if (error instanceof StateError) throw error;
    throw new StateError("Install deployment state is not valid JSON.", 66);
  }
  if (raw !== canonicalState(state)) {
    throw new StateError("Install deployment state is not canonical.", 66);
  }
  return state;
}

function writeInstallState(file, phase, revision, imageId, postgresVolume) {
  const { parent } = validateStatePath(file);
  const state = validateInstallState({
    schemaVersion: 1,
    phase,
    revision,
    imageId,
    postgresVolume
  });
  if (existsSync(file)) {
    const previous = readInstallState(file);
    const previousIndex = INSTALL_PHASES.indexOf(previous.phase);
    const nextIndex = INSTALL_PHASES.indexOf(state.phase);
    if (
      previous.revision !== state.revision
      || previous.imageId !== state.imageId
      || previous.postgresVolume !== state.postgresVolume
      || nextIndex < previousIndex
      || nextIndex > previousIndex + 1
    ) {
      throw new StateError("Install deployment state transition is invalid.", 67);
    }
  } else if (state.phase !== INSTALL_PHASES[0]) {
    throw new StateError("Install deployment state must begin at candidate-ready.", 67);
  }
  const temporary = join(parent, `.${basename(file)}.${randomUUID()}.tmp`);
  let descriptor;
  try {
    descriptor = openSync(
      temporary,
      constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
      0o600
    );
    writeFileSync(descriptor, canonicalState(state), { encoding: "utf8" });
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    renameSync(temporary, file);
    const directoryDescriptor = openSync(parent, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      fsyncSync(directoryDescriptor);
    } finally {
      closeSync(directoryDescriptor);
    }
  } catch (error) {
    if (descriptor !== undefined) closeSync(descriptor);
    try { unlinkSync(temporary); } catch {}
    if (error instanceof StateError) throw error;
    throw new StateError("Install deployment state could not be written atomically.", 74);
  }
  return state;
}

function deleteInstallState(file, revision, imageId, postgresVolume) {
  const { parent } = validateStatePath(file);
  const state = readInstallState(file);
  if (
    state.phase !== "roles-ready"
    || state.revision !== revision
    || state.imageId !== imageId
    || state.postgresVolume !== postgresVolume
  ) {
    throw new StateError("Install deployment state cleanup does not match the completed deployment.", 67);
  }
  try {
    unlinkSync(file);
    const directoryDescriptor = openSync(parent, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      fsyncSync(directoryDescriptor);
    } finally {
      closeSync(directoryDescriptor);
    }
  } catch {
    throw new StateError("Install deployment state could not be removed durably.", 74);
  }
}

async function readStandardInput() {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of process.stdin) {
    bytes += chunk.length;
    if (bytes > MAXIMUM_INPUT_BYTES) throw new StateError("Native config response is too large.");
    chunks.push(chunk);
  }
  const raw = Buffer.concat(chunks).toString("utf8");
  try {
    return JSON.parse(raw);
  } catch {
    throw new StateError("Native config response is not valid JSON.");
  }
}

async function main() {
  const [command, ...args] = process.argv.slice(2);
  switch (command) {
  case "fingerprint": {
    if (args.length !== 0) usage();
    const record = fingerprint(await readStandardInput());
    process.stdout.write(`${record.version}|${record.digest}|${record.updatedAtEpochMs}\n`);
    break;
  }
  case "release-gate": {
    if (args.length !== 2) usage();
    const [appVersion, bundledVersionRaw] = args;
    const bundledVersion = Number(bundledVersionRaw);
    if (!appVersionComponents(appVersion) || !boundedInteger(bundledVersion, 1, MAXIMUM_CONFIG_VERSION)) {
      throw new StateError("Release compatibility arguments are invalid.");
    }
    const config = validateConfig(await readStandardInput());
    if (config.configVersion < bundledVersion) {
      throw new StateError("Production config is older than the release's bundled policy.", 67);
    }
    if (
      config.minSupportedAppVersion !== undefined
      && compareAppVersions(appVersion, config.minSupportedAppVersion) < 0
    ) {
      throw new StateError("Production config does not support the release app version.", 67);
    }
    const record = fingerprint(config);
    process.stdout.write(`${record.version}|${record.digest}|${record.updatedAtEpochMs}\n`);
    break;
  }
  case "verify-response": {
    if (args.length !== 3) usage();
    verifyResponseHeaders(args[0], args[1], args[2]);
    break;
  }
  case "read": {
    if (args.length !== 1) usage();
    const state = readState(args[0]);
    process.stdout.write(
      `${state.version}|${state.digest}|${state.updatedAtEpochMs}|${state.revision}|${state.imageId}\n`
    );
    break;
  }
  case "validate": {
    if (args.length !== 1) usage();
    validateStatePath(args[0]);
    break;
  }
  case "write": {
    if (args.length !== 6) usage();
    const state = writeState(args[0], args[1], args[2], args[3], args[4], args[5]);
    process.stdout.write(
      `${state.version}|${state.digest}|${state.updatedAtEpochMs}|${state.revision}|${state.imageId}\n`
    );
    break;
  }
  case "install-read": {
    if (args.length !== 1) usage();
    const state = readInstallState(args[0]);
    process.stdout.write(
      `${state.phase}|${state.revision}|${state.imageId}|${state.postgresVolume}\n`
    );
    break;
  }
  case "install-write": {
    if (args.length !== 5) usage();
    const state = writeInstallState(args[0], args[1], args[2], args[3], args[4]);
    process.stdout.write(
      `${state.phase}|${state.revision}|${state.imageId}|${state.postgresVolume}\n`
    );
    break;
  }
  case "install-delete": {
    if (args.length !== 4) usage();
    deleteInstallState(args[0], args[1], args[2], args[3]);
    break;
  }
  default:
    usage();
  }
}

main().catch((error) => {
  const status = error instanceof StateError ? error.status : 70;
  const message = error instanceof StateError ? error.message : "Deployment state operation failed."
  process.stderr.write(`ERROR ${message}\n`);
  process.exit(status);
});
