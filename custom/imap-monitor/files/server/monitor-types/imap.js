const { MonitorType } = require("./monitor-type");
const { UP, PING_GLOBAL_TIMEOUT_DEFAULT: TIMEOUT } = require("../../src/util");
const { ImapFlow } = require("imapflow");
const net = require("net");
const tls = require("tls");

// IMAP response codes (RFC 5530) that mean the server refused the login for a reason
// other than the credentials themselves (account/service state), as opposed to a plain
// wrong-username/wrong-password rejection.
const NON_CREDENTIAL_LOGIN_REJECTION_CODES = new Set([
    "UNAVAILABLE",
    "CONTACTADMIN",
    "NOPERM",
    "INUSE",
    "SERVERBUG",
    "PRIVACYREQUIRED",
    "CANNOT",
    "LIMIT",
    "OVERQUOTA",
    "ALREADYEXISTS",
    "NONEXISTENT",
]);

// Node TLS/crypto error codes that specifically mean certificate validation failed
// (as opposed to a lower-level handshake failure that has nothing to do with the cert).
const TLS_CERTIFICATE_ERROR_CODES = new Set([
    "CERT_HAS_EXPIRED",
    "CERT_NOT_YET_VALID",
    "DEPTH_ZERO_SELF_SIGNED_CERT",
    "SELF_SIGNED_CERT_IN_CHAIN",
    "UNABLE_TO_VERIFY_LEAF_SIGNATURE",
    "UNABLE_TO_GET_ISSUER_CERT",
    "UNABLE_TO_GET_ISSUER_CERT_LOCALLY",
    "ERR_TLS_CERT_ALTNAME_INVALID",
    "CERT_UNTRUSTED",
    "CERT_REVOKED",
    "HOSTNAME_MISMATCH",
]);

// imapflow error codes (see node_modules/imapflow/lib/errors.js, exported as ImapFlowErrorCode)
// that mean the connection timed out before anything useful happened.
const CONNECTION_TIMEOUT_CODES = new Set(["CONNECT_TIMEOUT", "GREETING_TIMEOUT", "ETIMEDOUT", "ETIMEOUT"]);

// imapflow error codes that mean the connection dropped after it was already established,
// rather than ever having failed to connect in the first place.
const UNEXPECTED_CLOSE_CODES = new Set([
    "EConnectionClosed",
    "ClosedAfterConnectText",
    "ClosedAfterConnectTLS",
    "NoConnection",
]);

/**
 * Native IMAP monitor type.
 *
 * Verifies that a mailbox actually works, not just that something answers on the port:
 * connect, negotiate TLS/STARTTLS as configured, log in, and (depending on the configured
 * check type) open the configured mailbox - then log out again.
 */
class ImapMonitorType extends MonitorType {
    name = "imap";

    /**
     * @inheritdoc
     */
    async check(monitor, heartbeat, _server) {
        const checkType = monitor.imapCheckType || "authenticate_select";

        if (checkType === "connect") {
            await this.checkConnect(monitor, heartbeat);
            return;
        }

        await this.checkAuthenticate(monitor, heartbeat, checkType === "authenticate_select");
    }

    /**
     * Resolve the {secure, doSTARTTLS, defaultPort} triple for a monitor's imapSecurity setting.
     * @param {string} imapSecurity One of "secure" (implicit TLS), "starttls" or "none"
     * @returns {{secure: boolean, doSTARTTLS: boolean|undefined, defaultPort: number}} Resolved TLS settings
     */
    resolveSecurity(imapSecurity) {
        switch (imapSecurity) {
            case "starttls":
                // Must upgrade to TLS; fail (rather than silently staying in cleartext) if the
                // server does not offer STARTTLS.
                return { secure: false, doSTARTTLS: true, defaultPort: 143 };
            case "none":
                // Never upgrade, even if the server offers STARTTLS. Only sensible for
                // internal/test servers - the UI defaults new monitors to "secure".
                return { secure: false, doSTARTTLS: false, defaultPort: 143 };
            case "secure":
            default:
                return { secure: true, doSTARTTLS: undefined, defaultPort: 993 };
        }
    }

    /**
     * "Connect" check level: open a raw (TLS or plaintext) socket and confirm the server speaks
     * IMAP by reading its initial greeting. No credentials are used or required at this level.
     * @param {object} monitor Monitor object
     * @param {object} heartbeat Heartbeat object
     * @returns {Promise<void>}
     */
    checkConnect(monitor, heartbeat) {
        const { secure, defaultPort } = this.resolveSecurity(monitor.imapSecurity);
        const port = monitor.port || defaultPort;
        const timeoutMs = monitor.timeout ? monitor.timeout * 1000 : 1000 * TIMEOUT;

        return new Promise((resolve, reject) => {
            let settled = false;
            let buffer = "";

            const settle = (fn) => {
                if (settled) {
                    return;
                }
                settled = true;
                clearTimeout(timer);
                socket.removeAllListeners();
                socket.destroy();
                fn();
            };

            const connectOptions = {
                host: monitor.hostname,
                port,
                servername: monitor.hostname,
                rejectUnauthorized: !monitor.getIgnoreTls(),
            };

            const socket = secure ? tls.connect(connectOptions) : net.connect({ host: monitor.hostname, port });

            const timer = setTimeout(() => {
                settle(() => reject(Object.assign(new Error("Connection timed out"), { code: "ETIMEDOUT" })));
            }, timeoutMs);

            // Deliberately no "connect"/"secureConnect" listener: resolution waits for the
            // IMAP greeting line below, not just a successful TCP/TLS handshake.
            socket.on("data", (chunk) => {
                buffer += chunk.toString("utf8");
                if (buffer.includes("\r\n") || buffer.includes("\n")) {
                    settle(() => {
                        if (/^\*\s+OK/i.test(buffer)) {
                            resolve();
                        } else {
                            reject(new Error(`Unexpected greeting: ${buffer.trim()}`));
                        }
                    });
                }
            });

            socket.on("error", (err) => {
                settle(() => reject(err));
            });
        })
            .then(() => {
                heartbeat.status = UP;
                heartbeat.msg = "IMAP OK - greeting received";
            })
            .catch((err) => {
                throw this.mapConnectError(err);
            });
    }

    /**
     * "Authenticate" and "Authenticate + Select Mailbox" check levels, both backed by imapflow.
     * @param {object} monitor Monitor object
     * @param {object} heartbeat Heartbeat object
     * @param {boolean} selectMailbox Also open the configured mailbox after authenticating
     * @returns {Promise<void>}
     */
    async checkAuthenticate(monitor, heartbeat, selectMailbox) {
        const { secure, doSTARTTLS, defaultPort } = this.resolveSecurity(monitor.imapSecurity);
        const timeoutMs = monitor.timeout ? monitor.timeout * 1000 : 1000 * TIMEOUT;
        const mailbox = monitor.imapMailbox || "INBOX";

        const client = new ImapFlow({
            host: monitor.hostname,
            port: monitor.port || defaultPort,
            secure,
            doSTARTTLS,
            servername: monitor.hostname,
            // never send the password anywhere except the LOGIN command itself
            logger: false,
            auth: {
                user: monitor.imapUsername,
                pass: monitor.imapPassword,
            },
            tls: {
                rejectUnauthorized: !monitor.getIgnoreTls(),
            },
            connectionTimeout: timeoutMs,
            // "Authenticate" only: log in, then log out automatically inside connect().
            // "Authenticate + Select Mailbox" needs the connection to stay open afterwards.
            verifyOnly: !selectMailbox,
        });

        // A background socket error after connect() has already resolved is emitted as an
        // 'error' event rather than a rejected promise - without a listener this would crash
        // the whole Uptime Kuma process, not just this one check. The listener intentionally
        // does nothing with the error itself (never log credentials-adjacent IMAP state).
        client.on("error", () => {});
        client.on("close", () => {});

        try {
            await client.connect();
        } catch (err) {
            throw this.mapConnectError(err);
        }

        try {
            if (selectMailbox) {
                let lock;
                try {
                    lock = await client.getMailboxLock(mailbox);
                } catch (err) {
                    throw this.mapSelectError(err, mailbox);
                }
                lock.release();

                await client.logout();
                heartbeat.status = UP;
                heartbeat.msg = `IMAP OK - authenticated and mailbox ${mailbox} selected`;
            } else {
                // verifyOnly already logged out as part of connect() resolving successfully.
                heartbeat.status = UP;
                heartbeat.msg = "IMAP OK - authenticated";
            }
        } finally {
            client.close();
        }
    }

    /**
     * Translate a connect()-phase error (DNS, TCP, TLS or login) into one of the spec's
     * functional error messages.
     * @param {Error} err Error thrown by imapflow or the raw socket layer
     * @returns {Error} Error with a user-facing, functionally descriptive message
     */
    mapConnectError(err) {
        const code = err.code;

        if (code === "ENOTFOUND" || code === "EAI_AGAIN") {
            return new Error("DNS resolution failed");
        }

        if (CONNECTION_TIMEOUT_CODES.has(code)) {
            return new Error("IMAP connection timeout");
        }

        if (TLS_CERTIFICATE_ERROR_CODES.has(code) || err.authorizationError) {
            return new Error("TLS certificate validation failed");
        }

        if (err.library === "SSL routines" || (typeof code === "string" && code.startsWith("ERR_SSL_"))) {
            return new Error("TLS handshake failed");
        }

        if (err.authenticationFailed) {
            if (err.serverResponseCode && NON_CREDENTIAL_LOGIN_REJECTION_CODES.has(err.serverResponseCode)) {
                return new Error("IMAP server rejected login");
            }
            return new Error("IMAP authentication failed");
        }

        if (UNEXPECTED_CLOSE_CODES.has(code)) {
            return new Error("IMAP connection closed unexpectedly");
        }

        if (typeof code === "string" && code.startsWith("ParserError")) {
            return new Error("IMAP protocol error");
        }

        return new Error(`IMAP error: ${err.message}`);
    }

    /**
     * Translate a mailbox-select error into the spec's "Unable to select mailbox" message.
     * @param {Error} err Error thrown by imapflow's getMailboxLock()/mailboxOpen()
     * @param {string} mailbox Mailbox path that was requested
     * @returns {Error} Error with a user-facing, functionally descriptive message
     */
    mapSelectError(err, mailbox) {
        return new Error(`Unable to select mailbox ${mailbox}`);
    }
}

module.exports = {
    ImapMonitorType,
};
