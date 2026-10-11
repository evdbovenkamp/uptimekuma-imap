"use strict";

/**
 * Standalone rollback script for the IMAP monitor patch. Run it, once, from the PATCHED
 * image - never the stock one - against the stopped data volume, before switching the
 * compose file back to a stock Uptime Kuma image:
 *
 *   docker run --rm -v <data-volume>:/app/data --entrypoint node <patched-image> \
 *       extra/imap-migration-down.js
 *
 * It drops the imap_* columns from the "monitor" table AND removes this migration's
 * bookkeeping row from knex_migrations. Skipping the bookkeeping removal is not an option:
 * a stock image's migration directory has no file for this migration, so knex's default
 * migration-list validation rejects it on boot ("migration directory is corrupt") and the
 * container crash-loops. knex.migrate.down({ name }) handles both steps in one call.
 *
 * Idempotent: running it again when the migration was already rolled back is a no-op.
 */

const { R } = require("redbean-node");
const Database = require("../server/database");

const MIGRATION_NAME = "2026-10-11-1200-add-imap-monitor.js";

(async () => {
    Database.initDataDir({});
    await Database.connect(false, false, true);

    let alreadyRolledBack = false;
    try {
        const row = await R.getCell("SELECT COUNT(*) AS c FROM knex_migrations WHERE name = ?", [MIGRATION_NAME]);
        alreadyRolledBack = !row;
    } catch (err) {
        console.error(`[imap-migration-down] Could not read knex_migrations (${err.message}); assuming nothing to roll back.`);
        alreadyRolledBack = true;
    }

    if (alreadyRolledBack) {
        console.log(`[imap-migration-down] "${MIGRATION_NAME}" is not applied, nothing to roll back.`);
        process.exit(0);
    }

    // SQLite has no native multi-column DROP COLUMN, so knex rebuilds the "monitor" table
    // (copy to a new table, drop the old one). Other tables (heartbeat, tag, etc.) hold a
    // foreign key into monitor.id, and initSQLite() turns foreign_keys ON for every new
    // connection by default - dropping the old table under FK enforcement fails with
    // "FOREIGN KEY constraint failed". database.js brackets its own migrate.latest() call
    // the same way; mirror that here for migrate.down().
    await R.exec("PRAGMA foreign_keys = OFF");
    try {
        await R.knex.migrate.down({
            directory: Database.knexMigrationsPath,
            name: MIGRATION_NAME,
        });
    } finally {
        await R.exec("PRAGMA foreign_keys = ON");
    }

    console.log(`[imap-migration-down] Rolled back "${MIGRATION_NAME}" and removed its knex_migrations row.`);
    process.exit(0);
})().catch((err) => {
    console.error("[imap-migration-down] Failed:", err);
    process.exit(1);
});
