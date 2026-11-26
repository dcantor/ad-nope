// Safari toolbar popup: turn dark mode on or off, or skip the current site.
// Settings live in the Ad Nope app; changes go to it through the extension's
// native handler, so the app's Extras screen shows the same thing.

const $ = (id) => document.getElementById(id);
const native = (message) => browser.runtime.sendNativeMessage("com.dcantor.blocker", message);

let host = null;      // the current tab's site, from the content script
let settings = null;  // { enabled, mode, excluded }

const matches = (h, d) => h === d || h.endsWith("." + d);

async function activeTab() {
    const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
    return tab;
}

function render() {
    const excluded = host && (settings.excluded || []).some((d) => matches(host, d));
    $("all-toggle").checked = settings.enabled;
    $("site-toggle").checked = !!host && !excluded;
    $("site-toggle").disabled = !host || !settings.enabled;
    $("site").textContent = host ? host.replace(/^www\./, "") : "This page";
    $("note").textContent = !host
        ? "Ad Nope Dark isn't allowed on this page. Allow it in Safari's extension settings."
        : settings.mode === "always"
            ? "Light sites are darkened all the time. Sites that are already dark are left alone."
            : "Light sites are darkened while your device is in dark mode. Sites that are already dark are left alone.";
}

async function refreshPage() {
    const tab = await activeTab();
    if (tab) browser.tabs.sendMessage(tab.id, { type: "dark-refresh" }).catch(() => {});
}

async function init() {
    try {
        const tab = await activeTab();
        const info = await browser.tabs.sendMessage(tab.id, { type: "dark-host" });
        host = info && info.host;
    } catch (e) {
        host = null; // no content script here: not allowed on this site, or a special page
    }
    try {
        settings = await native({ type: "dark-settings" });
    } catch (e) {
        settings = { enabled: false, mode: "system", excluded: [] };
        $("note").textContent = "Couldn't reach the Ad Nope app's settings.";
    }
    render();
}

$("all-toggle").addEventListener("change", async (e) => {
    settings = await native({ type: "dark-set", enabled: e.target.checked });
    render();
    refreshPage();
});

$("site-toggle").addEventListener("change", async (e) => {
    settings = await native({ type: "dark-set", site: host, darken: e.target.checked });
    render();
    refreshPage();
});

init();
