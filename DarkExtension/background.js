// Fetches dark-mode settings from the Ad Nope app (via the extension's native
// handler) and hands them to content.js. Nothing about the page is sent to the
// app: content.js asks "what are the settings?" and decides locally.

let cached = null;

async function loadSettings() {
    try {
        // Safari routes this to the containing app's SafariWebExtensionHandler;
        // the application ID argument is ignored.
        const settings = await browser.runtime.sendNativeMessage("com.dcantor.blocker", { type: "dark-settings" });
        if (settings) {
            cached = settings;
            browser.storage.local.set({ settings });
        }
    } catch (e) {
        if (!cached) {
            cached = (await browser.storage.local.get("settings")).settings ?? null;
        }
    }
    return cached;
}

browser.runtime.onMessage.addListener((message) => {
    if (message && message.type === "dark-settings") {
        return loadSettings();
    }
});
