// Ad Nope Dark: gives light-only pages a dark look.
//
// How: invert the whole page's colors (with a hue rotation so reds stay red),
// then invert images, video and embeds back so they look normal. Pages that
// are already dark are left alone. Everything happens locally in the page;
// nothing is sent anywhere.

(() => {
    if (window.top !== window) return; // top frame only; iframes are flipped back by the page rule

    const CSS = `
html {
    filter: invert(0.9) hue-rotate(180deg) !important;
    background-color: #fff;
}
img, video, canvas, iframe, embed, object, svg image,
[style*="background-image"] {
    /* Exact inverse of the page filter: invert(0.9) maps x to 0.9 - 0.8x, and
       invert(1) then contrast(1.25) maps y back to 1.125 - 1.25y. */
    filter: hue-rotate(180deg) invert(1) contrast(1.25) !important;
}
[style*="background-image"] img,
[style*="background-image"] video {
    filter: none !important;
}`;

    let style = null;

    function apply() {
        if (style) return;
        style = document.createElement("style");
        style.id = "ad-nope-dark";
        style.textContent = CSS;
        (document.head || document.documentElement).appendChild(style);
    }

    function remove() {
        if (style) style.remove();
        style = null;
    }

    // 0 = black, 1 = white; null if the color is transparent or unreadable.
    function luminance(color) {
        const m = /rgba?\(([^)]+)\)/.exec(color || "");
        if (!m) return null;
        const [r, g, b, a = 1] = m[1].split(/[\s,/]+/).filter(Boolean).map(Number);
        if (a < 0.1) return null;
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
    }

    // Is the page dark on its own? Measured with our style switched off.
    function pageIsDark() {
        if (style && style.sheet) style.sheet.disabled = true;
        const body = document.body ? luminance(getComputedStyle(document.body).backgroundColor) : null;
        const html = luminance(getComputedStyle(document.documentElement).backgroundColor);
        if (style && style.sheet) style.sheet.disabled = false;
        const l = body ?? html;
        return l !== null && l < 0.4;
    }

    function matches(host, domain) {
        return host === domain || host.endsWith("." + domain);
    }

    browser.runtime.sendMessage({ type: "dark-settings" }).then((s) => {
        if (!s || !s.enabled) return;
        const host = location.hostname.toLowerCase();
        if ((s.excluded || []).some((d) => matches(host, d))) return;

        const deviceDark = window.matchMedia("(prefers-color-scheme: dark)");
        const wanted = () => s.mode === "always" || deviceDark.matches;

        const evaluate = () => {
            if (!wanted()) return remove();
            if (!document.body) return apply(); // too early to judge: darken now, re-check when the body exists
            if (pageIsDark()) remove(); else apply();
        };

        evaluate();
        if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", evaluate, { once: true });
        }
        window.addEventListener("load", evaluate, { once: true });
        deviceDark.addEventListener("change", evaluate);
    }).catch(() => {});
})();
