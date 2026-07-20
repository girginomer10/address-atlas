import { defineMigration } from "./types";

export const ACCOUNT_DELETION_RECEIPTS_MIGRATION = defineMigration({
  version: 3,
  name: "account-deletion-receipts",
  statements: [
    // Receipts intentionally do not expire. They contain no account linkage,
    // and permanent retention is what lets an offline client resolve a lost
    // successful response even if it relaunches months later.
    `CREATE TABLE account_deletion_receipts (
       idempotency_key_digest bytea PRIMARY KEY
         CONSTRAINT account_deletion_receipts_digest_length_check
         CHECK (octet_length(idempotency_key_digest) = 32),
       created_at timestamptz NOT NULL DEFAULT now()
     )`
  ]
});
