"use strict";

(() => {
  const markdown = globalThis.markdownit({ html: false });
  const remote = /^https?:\/\//i;
  // Relative SVG targets are accepted; links to workspace files are replaced by text plus the embedded image.
  markdown.validateLink = (url) => remote.test(url) || /^(?![a-z][a-z0-9+.-]*:|\/)[^?#]*\.svg(?:[?#].*)?$/i.test(url);
  markdown.core.ruler.push("local_links", (state) => {
    for (const block of state.tokens) {
      const hrefs = [];
      for (const token of block.children ?? []) {
        if (token.type === "link_open") {
          const href = token.attrGet("href") ?? "";
          const local = !remote.test(href);
          hrefs.push(local ? href : null);
          if (local) {
            token.type = "text";
            token.content = "";
            token.attrs = null;
          }
        } else if (token.type === "link_close") {
          const href = hrefs.pop();
          if (href != null) {
            token.type = "svg_link";
            token.content = href;
          }
        }
      }
    }
  });
  markdown.renderer.rules.svg_link = (tokens, index, options, env) => {
    const image = env.embed?.file(tokens[index].content, "SVG");
    return image ? `<br>${image}` : "";
  };
  markdown.renderer.rules.image = (tokens, index, options, env) => {
    const token = tokens[index];
    const embedded = env.embed?.file(token.attrGet("src") ?? "", token.content);
    return embedded ?? markdown.utils.escapeHtml(token.content);
  };
  // A block that starts with <svg and ends at </svg> becomes an image; other raw HTML stays escaped text.
  markdown.block.ruler.before("fence", "svg_block", (state, startLine, endLine, silent) => {
    if (state.sCount[startLine] - state.blkIndent >= 4) return false;
    const line = (n) => state.src.slice(state.bMarks[n] + state.tShift[n], state.eMarks[n]);
    if (!/^<svg[\s>]/i.test(line(startLine))) return false;
    let last = startLine;
    while (last < endLine && !/<\/svg\s*>/i.test(line(last))) last += 1;
    if (!/<\/svg\s*>/i.test(line(last))) return false;
    if (silent) return true;
    const token = state.push("svg_block", "", 0);
    token.content = state.getLines(startLine, last + 1, state.blkIndent, false);
    token.map = [startLine, last + 1];
    state.line = last + 1;
    return true;
  });
  markdown.renderer.rules.svg_block = (tokens, index, options, env) =>
    env.embed?.inline(tokens[index].content, "SVG")
    ?? `<pre><code>${markdown.utils.escapeHtml(tokens[index].content)}</code></pre>`;
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

  // Embeds SVG sources as isolated data-URI images; invalid or oversized SVG returns null.
  function embedder(base, assets) {
    let total = 0;
    function inline(svg, alt) {
      if (!/^\s*<svg[\s>]/i.test(svg)) return null;
      const source = /^\s*<svg[^>]*\sxmlns\s*=/i.test(svg)
        ? svg : svg.replace(/^(\s*)<svg/i, '$1<svg xmlns="http://www.w3.org/2000/svg"');
      const bytes = utf8.encode(source);
      if (total + bytes.length > maxSVGBytes) return null;
      const root = new DOMParser().parseFromString(source, "image/svg+xml").documentElement;
      if (root.localName !== "svg") return null;
      total += bytes.length;
      let binary = "";
      for (let offset = 0; offset < bytes.length; offset += 8192) {
        binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
      }
      return `<img alt="${markdown.utils.escapeHtml(alt)}" style="max-width:100%;height:auto" `
        + `src="data:image/svg+xml;base64,${btoa(binary)}">`;
    }
    return {
      file(src, alt) {
        const path = resolve(base, src);
        const svg = path === null || !path.toLowerCase().endsWith(".svg") ? undefined : assets[path];
        return typeof svg === "string" ? inline(svg, alt) : null;
      },
      inline,
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
