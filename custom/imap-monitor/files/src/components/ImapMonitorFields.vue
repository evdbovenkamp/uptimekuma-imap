<template>
    <!--
        Kept as its own component (rather than inline in EditMonitor.vue) so the IMAP-monitor
        patch only has to touch EditMonitor.vue for a single include line - every IMAP-specific
        field lives here, where an upstream EditMonitor.vue rewrite cannot conflict with it.
    -->
    <!-- Not required for the "connect" check type, which never authenticates. -->
    <div v-if="monitor.imapCheckType !== 'connect'" class="my-3">
        <label for="imapUsername" class="form-label">IMAP {{ $t("Username") }}</label>
        <input id="imapUsername" v-model="monitor.imapUsername" type="text" class="form-control" required />
    </div>

    <div v-if="monitor.imapCheckType !== 'connect'" class="my-3">
        <label for="imapPassword" class="form-label">IMAP {{ $t("Password") }}</label>
        <HiddenInput id="imapPassword" v-model="monitor.imapPassword" autocomplete="new-password" required="true" />
    </div>

    <div class="my-3">
        <label for="imapSecurity" class="form-label">IMAP {{ $t("Security") }}</label>
        <select id="imapSecurity" v-model="monitor.imapSecurity" class="form-select">
            <option value="secure">IMAPS ({{ $t("Port") }} 993)</option>
            <option value="starttls">STARTTLS ({{ $t("Port") }} 143)</option>
            <option value="none">{{ $t("None") }}</option>
        </select>
        <div class="form-text">
            {{ $t("imapSecurityHelpText") }}
        </div>
    </div>

    <div class="my-3">
        <label for="imapMailbox" class="form-label">{{ $t("imapMailboxLabel") }}</label>
        <input id="imapMailbox" v-model="monitor.imapMailbox" type="text" class="form-control" required />
        <div class="form-text">
            {{ $t("imapMailboxTip") }}
        </div>
    </div>

    <div class="my-3">
        <label for="imapCheckType" class="form-label">IMAP {{ $t("Check Type") }}</label>
        <select id="imapCheckType" v-model="monitor.imapCheckType" class="form-select" required>
            <option value="connect">{{ $t("imapCheckTypeConnect") }}</option>
            <option value="authenticate">{{ $t("imapCheckTypeAuthenticate") }}</option>
            <option value="authenticate_select">{{ $t("imapCheckTypeAuthenticateSelect") }}</option>
        </select>
        <div class="form-text">
            {{ $t("imapCheckTypeHelpText") }}
        </div>
    </div>
</template>

<script>
import HiddenInput from "./HiddenInput.vue";

export default {
    name: "ImapMonitorFields",

    components: {
        HiddenInput,
    },

    props: {
        /**
         * The monitor object being edited. Fields are bound directly (imapUsername,
         * imapPassword, imapSecurity, imapMailbox, imapCheckType) rather than through
         * v-model/emit, matching how EditMonitor.vue itself binds every other monitor-type
         * field straight to the shared monitor object.
         */
        monitor: {
            type: Object,
            required: true,
        },
    },
};
</script>
