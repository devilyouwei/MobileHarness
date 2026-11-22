"use strict";

(() => {
  const markdown = globalThis.markdownit({ html: false });
  const remote = /^https?:\/\//i;
  // Relative SVG targets are accepted for images only; links to them are unwrapped below.
  markdown.validateLink = (url) => remote.test(url) || /^(?![a-z][a-z0-9+.-]*:|\/)[^?#]*\.svg(?:[?#].*)?$/i.test(url);
  markdown.core.ruler.push("local_links", (state) => {
    for (const block of state.tokens) {
      let unwrap = [];
      for (const token of block.children ?? []) {
        if (token.type === "link_open") {
          const local = !remote.test(token.attrGet("href") ?? "");
          unwrap.push(local);
          if (local) {
            token.type = "text";
            token.content = "";
            token.attrs = null;
          }
        } else if (token.type === "link_close" && unwrap.pop()) {
          token.type = "text";
          token.content = "";
        }
      }
    }
  });
  markdown.renderer.rules.image = (tokens, index, options, env) => {
    const token = tokens[index];
    const embedded = env.embed?.(token.attrGet("src") ?? "", token.content);
    return embedded ?? markdown.utils.escapeHtml(token.content);
  };
  const renderFence = markdown.renderer.rules.fence;
  markdown.renderer.rules.fence = (tokens, index, options, env, renderer) =>
    env.diagrams.get(tokens[index]) ?? renderFence(tokens, index, options, env, renderer);

  const maxDiagramBytes = 16 * 1024;
  const maxDiagramCount = 16;
  const maxSVGBytes = 2 * 1024 * 1024;
  const utf8 = new TextEncoder();
  let library;

  function loadMermaid() {
    library ??= new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = "mermaid-12.3.0.min.js";
      script.onerror = () => reject(new Error("Mermaid renderer could not load"));
      script.onload = () => {
        if (globalThis.mermaid) {
          resolve(globalThis.mermaid);
        } else {
          reject(new Error("Mermaid renderer did not initialize"));
        }
      };
      document.head.append(script);
    });
    return library;
  }

  function image(svg, bytes, number, diagramLabel) {
    const element = new DOMParser().parseFromString(svg, "image/svg+xml").documentElement;
    if (element.localName !== "svg") throw new Error("No valid SVG was generated");
    const viewBox = element.getAttribute("viewBox")?.trim().split(/[\s,]+/).map(Number);
    if (!viewBox || viewBox.length !== 4 || !viewBox.every(Number.isFinite) || viewBox[2] <= 0 || viewBox[3] <= 0) {
      throw new Error("Invalid diagram dimensions");
    }
    let binary = "";
    for (let offset = 0; offset < bytes.length; offset += 8192) {
      binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
    }
    const [width, height] = viewBox.slice(2).map(Math.ceil);
    return `<figure class="mermaid-diagram" data-key="mermaid-${number}"><img alt="${markdown.utils.escapeHtml(diagramLabel)} ${number}" `
      + `width="${width}" height="${height}" src="data:image/svg+xml;base64,${btoa(binary)}"></figure>`;
  }

  function resolve(base, target) {
    let decoded;
    try { decoded = decodeURIComponent(target.split(/[?#]/, 1)[0]); } catch { return null; }
    if (!decoded || decoded.startsWith("/") || /^[a-z][a-z0-9+.-]*:/i.test(decoded)) return null;
    const parts = base.split("/").slice(0, -1);
    for (const part of decoded.split("/")) {
      if (part === "" || part === ".") continue;
      if (part === "..") {
        if (!parts.length) return null;
        parts.pop();
      } else {
        parts.push(part);
      }
    }
    return parts.join("/");
  }

  // Embeds workspace SVG files as isolated data-URI images; anything else keeps alt text.
  function embedder(base, assets) {
    let total = 0;
    return (src, alt) => {
      const path = resolve(base, src);
      const svg = path === null || !path.toLowerCase().endsWith(".svg") ? undefined : assets[path];
      if (typeof svg !== "string") return null;
      const bytes = utf8.encode(svg);
      if (total + bytes.length > maxSVGBytes) return null;
      const root = new DOMParser().parseFromString(svg, "image/svg+xml").documentElement;
      if (root.localName !== "svg") return null;
      total += bytes.length;
      let binary = "";
      for (let offset = 0; offset < bytes.length; offset += 8192) {
        binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
      }
      return `<img alt="${markdown.utils.escapeHtml(alt)}" style="max-width:100%;height:auto" `
        + `src="data:image/svg+xml;base64,${btoa(binary)}">`;
    };
  }

  globalThis.renderMobileHarnessMarkdown = async (source, labels, base = "", assets = {}) => {
    const env = { diagrams: new Map(), embed: embedder(base, assets) };
    const tokens = markdown.parse(source, env);
    const diagnostics = [];
    let number = 0;
    let svgBytes = 0;
    let mermaid;
    for (const [index, token] of tokens.entries()) {
      if (token.type !== "fence" || token.info.trim().split(/\s+/, 1)[0].toLowerCase() !== "mermaid") continue;
      number += 1;
      const problem = number > maxDiagramCount ? "Too many diagrams"
        : utf8.encode(token.content).length > maxDiagramBytes ? "Diagram source is too long"
        : /^\s*---(?:[ \t]*\r?\n)/.test(token.content) || /%%\s*\{/.test(token.content) ? "Diagram rendering configuration is unsupported"
        : null;
      if (!problem && !mermaid) {
        mermaid = await loadMermaid();
        mermaid.initialize({
          startOnLoad: false, securityLevel: "strict", htmlLabels: false, layout: "dagre",
          suppressErrorRendering: true, maxTextSize: maxDiagramBytes, maxEdges: 250,
          fontFamily: "system-ui, sans-serif",
        });
      }
      try {
        if (problem) throw new Error(problem);
        const { svg } = await mermaid.render(`writer-mermaid-${number}`, token.content);
        const bytes = utf8.encode(svg);
        if (svgBytes + bytes.length > maxSVGBytes) throw new Error("Combined diagram size limit exceeded");
        env.diagrams.set(token, image(svg, bytes, number, labels.diagram));
        svgBytes += bytes.length;
      } catch (error) {
        const reason = String(error?.message ?? error).split("\n", 1)[0].slice(0, 180);
        const message = `${labels.renderFailed} ${number} (${reason})`;
        if (diagnostics.length < 8) diagnostics.push(`Could not render diagram ${number} (${reason})`);
        const code = renderFence(tokens, index, markdown.options, env, markdown.renderer);
        env.diagrams.set(token, `<div class="mermaid-failure"><p>${markdown.utils.escapeHtml(message)}</p>${code}</div>`);
      }
    }
    return JSON.stringify({
      html: markdown.renderer.render(tokens, markdown.options, env),
      diagnostics: diagnostics.join("\n"),
    });
  };
})();
