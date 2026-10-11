exports.up = function (knex) {
    return knex.schema.alterTable("monitor", function (table) {
        table.string("imap_username");
        table.string("imap_password");
        table.string("imap_security").defaultTo("secure");
        table.string("imap_mailbox").defaultTo("INBOX");
        table.string("imap_check_type").defaultTo("authenticate_select");
    });
};

exports.down = function (knex) {
    return knex.schema.alterTable("monitor", function (table) {
        table.dropColumn("imap_username");
        table.dropColumn("imap_password");
        table.dropColumn("imap_security");
        table.dropColumn("imap_mailbox");
        table.dropColumn("imap_check_type");
    });
};
