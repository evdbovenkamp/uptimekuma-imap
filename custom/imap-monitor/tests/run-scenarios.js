"use strict";
/**
 * Exercises server/monitor-types/imap.js directly against the five functional-test
 * scenarios from functional-test-checklist.md, using the exact code and imapflow version
 * shipped in a given image. Run inside that image, e.g.:
 *
 *   docker run --rm --entrypoint node \
 *       -e IMAP_TEST_HOST=... -e IMAP_TEST_USER=... -e IMAP_TEST_PASS=... \
 *       <image-tag> /tmp/run-scenarios.js
 *
 * Never logs IMAP_TEST_PASS itself.
 */
const { ImapMonitorType } = require("./server/monitor-types/imap");

const HOST = process.env.IMAP_TEST_HOST;
const USER = process.env.IMAP_TEST_USER;
const PASS = process.env.IMAP_TEST_PASS;
const BARE_IP_HOST = process.env.IMAP_TEST_BARE_IP_HOST || HOST;

if (!HOST || !USER || !PASS) {
    console.error("IMAP_TEST_HOST, IMAP_TEST_USER and IMAP_TEST_PASS are required");
    process.exit(1);
}

const monitorType = new ImapMonitorType();

function makeMonitor(overrides) {
    return Object.assign(
        {
            hostname: HOST,
            port: 993,
            imapUsername: USER,
            imapPassword: PASS,
            imapSecurity: "secure",
            imapMailbox: "INBOX",
            imapCheckType: "authenticate_select",
            timeout: 10,
            getIgnoreTls: () => false,
        },
        overrides
    );
}

async function runScenario(name, monitor, expectedStatus) {
    const heartbeat = {};
    let result;
    try {
        await monitorType.check(monitor, heartbeat, null);
        result = { status: "UP", msg: heartbeat.msg };
    } catch (err) {
        result = { status: "DOWN", msg: err.message };
    }
    const ok = result.status === expectedStatus;
    console.log(`[${ok ? "PASS" : "FAIL"}] ${name}: ${result.status} - ${result.msg}`);
    return ok;
}

(async () => {
    let allOk = true;

    allOk =
        (await runScenario("1. Valid credentials, authenticate_select", makeMonitor({}), "UP")) && allOk;

    allOk =
        (await runScenario(
            "2. Wrong password",
            makeMonitor({ imapPassword: PASS + "-definitely-wrong" }),
            "DOWN"
        )) && allOk;

    allOk =
        (await runScenario(
            "3. Nonexistent mailbox",
            makeMonitor({ imapMailbox: "Does-Not-Exist-" + Date.now() }),
            "DOWN"
        )) && allOk;

    allOk =
        (await runScenario(
            "4a. Unreachable host (TEST-NET-1, timeout)",
            makeMonitor({ hostname: "192.0.2.1", timeout: 5 }),
            "DOWN"
        )) && allOk;

    allOk =
        (await runScenario(
            "4b. DNS resolution failure",
            makeMonitor({ hostname: "nonexistent.invalid", timeout: 5 }),
            "DOWN"
        )) && allOk;

    allOk =
        (await runScenario(
            "5. Invalid TLS certificate (bare IP, SAN mismatch)",
            makeMonitor({ hostname: BARE_IP_HOST }),
            "DOWN"
        )) && allOk;

    allOk =
        (await runScenario(
            "5b. ignoreTls toggle flips the same case to UP",
            makeMonitor({ hostname: BARE_IP_HOST, getIgnoreTls: () => true }),
            "UP"
        )) && allOk;

    process.exit(allOk ? 0 : 1);
})();
