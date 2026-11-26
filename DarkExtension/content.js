// Ad Nope Dark: gives light-only pages a dark look.
//
// How: invert the whole page's colors (with a hue rotation so reds stay red),
// then flip back the parts that should keep their real colors:
//   - images, video and embeds
//   - blocks that are already dark (a dark header should stay dark, not turn light)
//   - blocks where text sits on top of a large photo (hero tiles), so the text
//     stays readable against its photo
// Pages that are already dark are left alone. Everything happens locally in
// the page; nothing is sent anywhere.

(() => {
    if (window.top !== window) return; // top frame only; iframes are flipped back by the page rule

    // Exact inverse of the page filter: invert(0.9) maps x to 0.9 - 0.8x, and
    // invert(1) then contrast(1.25) maps it back (1.125 - 1.25y).
    const UNDO = "hue-rotate(180deg) invert(1) contrast(1.25)";
    const KEEP = "data-ad-nope-keep";
    const CSS = `
html {
    filter: invert(0.9) hue-rotate(180deg) !important;
    background-color: #fff;
}
img, video, canvas, iframe, embed, object, svg image,
[style*="background-image"], [${KEEP}] {
    filter: ${UNDO} !important;
}
[style*="background-image"] img, [style*="background-image"] video,
[${KEEP}] img, [${KEEP}] video, [${KEEP}] canvas, [${KEEP}] iframe, [${KEEP}] embed,
[${KEEP}] object, [${KEEP}] svg image, [${KEEP}] [style*="background-image"] {
    filter: none !important;
}`;

    let style = null;
    let settings = null;
    let observer = null;
    let scanTimer = null;

    // 0 = black, 1 = white; null if the color is transparent or unreadable.
    function luminance(color) {
        const m = /rgba?\(([^)]+)\)/.exec(color || "");
        if (!m) return null;
        const [r, g, b, a = 1] = m[1].split(/[\s,/]+/).filter(Boolean).map(Number);
        if (a < 0.5) return null;
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
    }

    // Runs fn with our styles switched off, so it sees the page's real colors.
    function measuring(fn) {
        if (style && style.sheet) style.sheet.disabled = true;
        try { return fn(); } finally { if (style && style.sheet) style.sheet.disabled = false; }
    }

    // Is the page dark on its own?
    function pageIsDark() {
        return measuring(() => {
            const body = document.body ? luminance(getComputedStyle(document.body).backgroundColor) : null;
            const html = luminance(getComputedStyle(document.documentElement).backgroundColor);
            const l = body ?? html;
            return l !== null && l < 0.4;
        });
    }

    const MEDIA = new Set(["IMG", "VIDEO", "CANVAS", "IFRAME", "EMBED", "OBJECT", "PICTURE", "SVG", "SCRIPT", "STYLE", "NOSCRIPT"]);
    const TEXT = "h1, h2, h3, h4, h5, p, a, button, li, span";

    function overlaps(a, b) {
        return a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
    }

    // Marks the blocks that should keep their real colors (see the top comment).
    function markKeepBlocks() {
        if (!style || !document.body) return;
        measuring(() => {
            document.querySelectorAll(`[${KEEP}]`).forEach((el) => el.removeAttribute(KEEP));
            let budget = 6000; // enough for big pages, bounded for huge ones

            // Already-dark blocks. Don't descend into a marked block: everything
            // inside it already keeps its colors.
            const walk = (parent) => {
                for (const el of parent.children) {
                    if (--budget < 0) return;
                    if (MEDIA.has(el.tagName.toUpperCase())) continue;
                    const l = luminance(getComputedStyle(el).backgroundColor);
                    if (l !== null && l < 0.3) el.setAttribute(KEEP, "");
                    else walk(el);
                }
            };
            walk(document.body);

            // Text on top of a large photo: keep the photo and its text together.
            const minW = Math.min(window.innerWidth * 0.6, 600);
            for (const img of document.querySelectorAll("img, picture, video")) {
                if (img.closest(`[${KEEP}]`)) continue;
                const r = img.getBoundingClientRect();
                if (r.width < minW || r.height < 200) continue;
                let anc = img.parentElement;
                for (let depth = 0; anc && anc !== document.body && depth < 6; depth++, anc = anc.parentElement) {
                    const texts = [...anc.querySelectorAll(TEXT)].slice(0, 40);
                    const covered = texts.some((t) =>
                        !t.contains(img) && !img.contains(t) && t.textContent.trim() && overlaps(t.getBoundingClientRect(), r));
                    if (covered) { anc.setAttribute(KEEP, ""); break; }
                }
            }
        });
    }

    function apply() {
        if (!style) {
            style = document.createElement("style");
            style.id = "ad-nope-dark";
            style.textContent = CSS;
            (document.head || document.documentElement).appendChild(style);
        }
        if (document.body) {
            markKeepBlocks();
            if (!observer) {
                // Pages that load content later: re-check, at most about once a second.
                observer = new MutationObserver(() => {
                    if (scanTimer) return;
                    scanTimer = setTimeout(() => { scanTimer = null; markKeepBlocks(); }, 1000);
                });
                observer.observe(document.body, { childList: true, subtree: true });
            }
        }
    }

    function remove() {
        if (style) style.remove();
        style = null;
        if (observer) observer.disconnect();
        observer = null;
        document.querySelectorAll(`[${KEEP}]`).forEach((el) => el.removeAttribute(KEEP));
    }

    const host = location.hostname.toLowerCase();
    const deviceDark = window.matchMedia("(prefers-color-scheme: dark)");

    function wanted() {
        if (!settings || !settings.enabled) return false;
        if ((settings.excluded || []).some((d) => host === d || host.endsWith("." + d))) return false;
        return settings.mode === "always" || deviceDark.matches;
    }

    function evaluate() {
        if (!wanted()) return remove();
        if (!document.body) return apply(); // too early to judge: darken now, re-check when the body exists
        if (pageIsDark()) remove(); else apply();
    }

    async function loadAndEvaluate() {
        try { settings = await browser.runtime.sendMessage({ type: "dark-settings" }); } catch (e) { /* keep last */ }
        evaluate();
    }

    // Messages from the toolbar popup.
    browser.runtime.onMessage.addListener((message) => {
        if (!message) return;
        if (message.type === "dark-host") {
            return Promise.resolve({ host, darkened: !!style });
        }
        if (message.type === "dark-refresh") {
            return loadAndEvaluate().then(() => ({ darkened: !!style }));
        }
    });

    loadAndEvaluate();
    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", evaluate, { once: true });
    }
    window.addEventListener("load", evaluate, { once: true });
    deviceDark.addEventListener("change", evaluate);
})();
