"use strict";

(() => {
  const markdown = globalThis.markdownit({ html: false });
  markdown.validateLink = (url) => /^https?:\/\//i.test(url);
  markdown.renderer.rules.image = (tokens, index) => markdown.utils.escapeHtml(tokens[index].content);
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

  globalThis.renderMobileHarnessMarkdown = async (source, labels) => {
    const env = { diagrams: new Map() };
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
