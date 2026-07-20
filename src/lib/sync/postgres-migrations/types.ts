import { createHash } from "node:crypto";

export interface SyncMigrationDefinition {
  readonly version: number;
  readonly name: string;
  readonly statements: readonly string[];
}

export interface SyncMigration extends SyncMigrationDefinition {
  readonly checksum: string;
}

export function defineMigration(definition: SyncMigrationDefinition): SyncMigration {
  if (!Number.isInteger(definition.version) || definition.version <= 0) {
    throw new Error("Sync migration versions must be positive integers.");
  }
  if (!/^[a-z0-9-]{1,80}$/.test(definition.name)) {
    throw new Error("Sync migration names must be stable kebab-case identifiers.");
  }
  if (definition.statements.length === 0 || definition.statements.some((sql) => !sql.trim())) {
    throw new Error("Sync migrations must contain non-empty SQL statements.");
  }

  const checksum = createHash("sha256")
    .update(JSON.stringify({
      version: definition.version,
      name: definition.name,
      statements: definition.statements
    }))
    .digest("hex");
  return Object.freeze({ ...definition, checksum });
}
