// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0
//
// Shared pieces of the App Store asset templates: device frames drawn as vectors, the app icon, the
// puppet strings, and where the pictures are. A classic script, because a page opened from a file
// cannot import a module. Scripts/store-assets.sh renders the pages with headless Chrome.

(function (root) {
    // Screen geometry in pixels, device upright. `radius` is the screen's corner radius, `bezel` the
    // black border around the screen and `rim` the metal edge outside it.
    const DEVICES = {
        iphone: { name: "iPhone", screen: [1206, 2622], radius: 186, bezel: 30, rim: 13, island: { width: 378, height: 111, top: 33 } },
        ipad: { name: "iPad", screen: [2064, 2752], radius: 62, bezel: 86, rim: 11 },
        // Open flat. Upright, the fold runs across the screen; on its side it runs down the middle.
        duo: { name: "iPhone Duo", screen: [2007, 2853], radius: 150, bezel: 40, rim: 14, fold: true },
    };

    // Everything a page reads is found from the templates' own place in the repository, so a page
    // needs no parameters to find its pictures.
    const CAPTURES = "../../../Artifacts/app-store/captures";
    const ICON_LAYERS = "../../../App/Marionette/Resources/AppIcon.icon/Assets";

    let serial = 0;

    /// The address of a capture: `capture("iphone", "session-landscape-chevron")`.
    function capture(device, name) {
        return `${CAPTURES}/${device}/${name}.png`;
    }

    /// The app icon as one flat SVG, composed from the layers of AppIcon.icon so that it follows
    /// the app's. icon.json gives the order (front to back: control, front strings, laptop and its
    /// screen, back string) and the colours. Reading the layers needs Chrome's
    /// --allow-file-access-from-files; without it the icon is left out.
    function iconSVG() {
        const layer = (name, fill, opacity = 1) => {
            const request = new XMLHttpRequest();
            request.open("GET", `${ICON_LAYERS}/${encodeURIComponent(name)}.svg`, false);
            request.send();
            const drawing = request.responseText.replace(/^[\s\S]*?<svg[^>]*>/, "").replace(/<\/svg>\s*$/, "");
            return `<g opacity="${opacity}">${drawing.replaceAll('fill="#ffffff"', `fill="${fill}"`)}</g>`;
        };
        try {
            return `<svg class="app-icon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="icon-field" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#f55c47"/><stop offset="1" stop-color="#a31433"/></linearGradient>
  <clipPath id="icon-shape"><rect width="1024" height="1024" rx="230"/></clipPath>
</defs>
<g clip-path="url(#icon-shape)">
  <rect width="1024" height="1024" fill="url(#icon-field)"/>
  ${layer("Back String", "#ffffff", 0.75)}
  ${layer("Laptop", "#ffffff")}
  ${layer("Screen", "#80102a")}
  ${layer("Front Strings", "#ffffff")}
  ${layer("Control", "#ffffff")}
</g>
</svg>`;
        } catch {
            return "";
        }
    }

    /// An SVG of a device holding `href` as its screen. The viewBox is the device's outer size in
    /// screen pixels, so the same drawing serves at any scale.
    function frameSVG(key, options = {}) {
        const device = DEVICES[key];
        const landscape = options.landscape ?? false;
        const [w, h] = landscape ? [device.screen[1], device.screen[0]] : device.screen;
        const edge = device.bezel + device.rim;
        const W = w + 2 * edge, H = h + 2 * edge;
        const id = `frame${++serial}`;
        const outer = device.radius + edge;
        const parts = [];
        parts.push(`<svg class="device-frame" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 ${W} ${H}" data-screen="${edge} ${edge} ${w} ${h}">`);
        parts.push(`<defs>
  <clipPath id="${id}-clip"><rect x="${edge}" y="${edge}" width="${w}" height="${h}" rx="${device.radius}"/></clipPath>
  <linearGradient id="${id}-rim" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#8e8e93"/><stop offset="0.25" stop-color="#48484a"/>
    <stop offset="0.6" stop-color="#2c2c2e"/><stop offset="1" stop-color="#636366"/>
  </linearGradient>
  <linearGradient id="${id}-fold" x1="0" y1="0" x2="${landscape ? 1 : 0}" y2="${landscape ? 0 : 1}">
    <stop offset="0" stop-color="#000" stop-opacity="0"/><stop offset="0.5" stop-color="#000" stop-opacity="0.09"/>
    <stop offset="1" stop-color="#000" stop-opacity="0"/>
  </linearGradient>
</defs>`);
        parts.push(`<rect width="${W}" height="${H}" rx="${outer}" fill="url(#${id}-rim)"/>`);
        parts.push(`<rect x="${device.rim}" y="${device.rim}" width="${W - 2 * device.rim}" height="${H - 2 * device.rim}" rx="${outer - device.rim}" fill="#050506"/>`);
        if (options.href) {
            parts.push(`<image href="${options.href}" xlink:href="${options.href}" x="${edge}" y="${edge}" width="${w}" height="${h}" preserveAspectRatio="none" clip-path="url(#${id}-clip)"/>`);
        } else {
            parts.push(`<rect id="screen" x="${edge}" y="${edge}" width="${w}" height="${h}" rx="${device.radius}" fill="#1c1c1e"/>`);
        }
        if (device.island) {
            const { width, height, top } = device.island;
            const rect = landscape
                ? { x: edge + top, y: edge + (h - width) / 2, width: height, height: width }
                : { x: edge + (w - width) / 2, y: edge + top, width, height };
            parts.push(`<rect x="${rect.x}" y="${rect.y}" width="${rect.width}" height="${rect.height}" rx="${height / 2}" fill="#000"/>`);
        }
        if (device.fold) {
            const band = 34;
            parts.push(landscape
                ? `<rect x="${edge + w / 2 - band / 2}" y="${edge}" width="${band}" height="${h}" fill="url(#${id}-fold)"/>`
                : `<rect x="${edge}" y="${edge + h / 2 - band / 2}" width="${w}" height="${band}" fill="url(#${id}-fold)"/>`);
        }
        // A hairline of light where the screen meets the bezel, so a dark picture still has an edge.
        parts.push(`<rect x="${edge - 1.5}" y="${edge - 1.5}" width="${w + 3}" height="${h + 3}" rx="${device.radius + 1.5}" fill="none" stroke="#fff" stroke-opacity="0.07" stroke-width="3"/>`);
        parts.push(`</svg>`);
        return parts.join("\n");
    }

    /// The outer width over height of a framed device.
    function frameAspect(key, landscape) {
        const device = DEVICES[key];
        const edge = 2 * (device.bezel + device.rim);
        const [w, h] = landscape ? [device.screen[1], device.screen[0]] : device.screen;
        return (w + edge) / (h + edge);
    }

    /// Query parameters of the page, with defaults.
    function parameters(defaults) {
        const query = new URLSearchParams(root.location.search);
        const result = { ...defaults };
        for (const [key, value] of query) result[key] = value;
        return result;
    }

    /// Draws the puppet strings: vertical lines from the top of `canvas` down to points on the top
    /// edge of `target`, given as fractions of its width. Returns the SVG element.
    function drawStrings(canvas, target, options = {}) {
        const fractions = options.fractions ?? [0.16, 0.84];
        const width = options.width ?? 6;
        const bounds = canvas.getBoundingClientRect();
        // The target may be rotated: find its top edge from its untransformed box and its transform.
        const box = { width: target.offsetWidth, height: target.offsetHeight };
        // Only the turn matters here; where the transform moves the target is already in its rect.
        const turned = new DOMMatrixReadOnly(getComputedStyle(target).transform);
        const matrix = new DOMMatrixReadOnly([turned.a, turned.b, turned.c, turned.d, 0, 0]);
        const rect = target.getBoundingClientRect();
        const centre = { x: rect.left + rect.width / 2 - bounds.left, y: rect.top + rect.height / 2 - bounds.top };
        const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
        svg.setAttribute("class", "strings");
        // No viewBox: the coordinates are the canvas's own pixels. The window's height is not final
        // while the page loads, and a viewBox measured now would be stretched later.
        svg.style.cssText = "position:absolute;left:0;top:0;width:100%;height:100%;overflow:visible;pointer-events:none";
        for (const [index, fraction] of fractions.entries()) {
            const local = new DOMPoint((fraction - 0.5) * box.width, -box.height / 2 + (options.inset ?? 0));
            const point = matrix.transformPoint(local);
            const x = centre.x + point.x, y = centre.y + point.y;
            const opacity = (options.opacities ?? [])[index] ?? 0.92;
            const line = document.createElementNS("http://www.w3.org/2000/svg", "line");
            line.setAttribute("x1", x); line.setAttribute("x2", x);
            line.setAttribute("y1", -width); line.setAttribute("y2", y);
            line.setAttribute("stroke", "#fff"); line.setAttribute("stroke-opacity", opacity);
            line.setAttribute("stroke-width", width); line.setAttribute("stroke-linecap", "round");
            svg.appendChild(line);
            const knot = document.createElementNS("http://www.w3.org/2000/svg", "circle");
            knot.setAttribute("cx", x); knot.setAttribute("cy", y); knot.setAttribute("r", width * 1.5);
            knot.setAttribute("fill", "#fff"); knot.setAttribute("fill-opacity", opacity);
            svg.appendChild(knot);
        }
        return svg;
    }

    /// Outlines an "art safe area" given in pixels of the final asset, when the page is asked for guides.
    function drawGuide(canvas, area, full) {
        const guide = document.createElement("div");
        guide.className = "guide";
        guide.style.cssText = `position:absolute;left:${(area.x / full.width) * 100}%;top:${(area.y / full.height) * 100}%;` +
            `width:${(area.width / full.width) * 100}%;height:${(area.height / full.height) * 100}%;` +
            "outline:2px dashed #0ff;box-shadow:0 0 0 9999px rgba(0,0,0,0.35);z-index:10;pointer-events:none";
        canvas.appendChild(guide);
    }

    /// Hangs a framed device in `canvas` from strings. Positions are in pixels of the finished
    /// asset (`full.width` across): `x`, `y` is the device's centre and `width` its outer width.
    /// `aux` marks supporting artwork, which is dimmed a little so the main device stays the subject.
    function hang(canvas, full, item) {
        const unit = canvas.getBoundingClientRect().width / full.width;
        const element = document.createElement("div");
        element.className = "device shadowed" + (item.aux ? " aux" : "");
        const height = item.width / frameAspect(item.device, item.landscape);
        element.style.cssText = `position:absolute;left:${(item.x - item.width / 2) * unit}px;top:${(item.y - height / 2) * unit}px;` +
            `width:${item.width * unit}px;height:${height * unit}px;transform:rotate(${item.rotate ?? 0}deg)`;
        element.innerHTML = frameSVG(item.device, { landscape: item.landscape, href: item.shot });
        canvas.appendChild(element);
        const strings = drawStrings(canvas, element, {
            fractions: item.strings ?? [0.14, 0.5, 0.86],
            opacities: (item.strings ?? [0, 1, 2]).map((_, index, all) => (all.length === 3 && index === 1 ? 0.5 : 0.95) * (item.aux ? 0.55 : 1)),
            width: (item.stringWidth ?? 14) * unit,
            inset: 6 * unit,
        });
        canvas.insertBefore(strings, element);
        return element;
    }

    root.Store = { DEVICES, capture, iconSVG, frameSVG, frameAspect, parameters, drawStrings, drawGuide, hang };
})(window);
