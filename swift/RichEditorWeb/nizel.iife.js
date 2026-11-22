"use strict";
var NizelKit = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // src/index.ts
  var index_exports = {};
  __export(index_exports, {
    createPlugins: () => createPlugins,
    defaultEnabledPlugins: () => defaultEnabledPlugins,
    markdownToHtml: () => markdownToHtml,
    mountMarkdown: () => mountMarkdown2,
    normalizeEnabledPlugins: () => normalizeEnabledPlugins,
    supportedPlugins: () => supportedPlugins,
    useNizelKit: () => useNizelKit
  });

  // ../nizel/dist/html-to-markdown.js
  var blockTags = /* @__PURE__ */ new Set([
    "address",
    "article",
    "aside",
    "blockquote",
    "details",
    "dialog",
    "div",
    "dl",
    "fieldset",
    "figcaption",
    "figure",
    "footer",
    "form",
    "header",
    "hr",
    "main",
    "nav",
    "ol",
    "p",
    "pre",
    "section",
    "table",
    "ul",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6"
  ]);
  var passthroughInlineTags = /* @__PURE__ */ new Set(["abbr", "bdi", "bdo", "cite", "data", "dfn", "kbd", "mark", "q", "samp", "small", "sub", "sup", "time", "u", "var"]);
  function htmlToMarkdown(html, options = {}) {
    const resolved = {
      unsupported: options.unsupported ?? "preserve",
      plugins: options.plugins ?? []
    };
    const handlers = resolved.plugins.flatMap((plugin) => {
      const handler = plugin?.htmlToMarkdown;
      return handler ? Array.isArray(handler) ? handler : [handler] : [];
    });
    const ctx = { options: resolved, handlers, epilogue: [] };
    const root = parseHtml(html);
    const body = normalizeDocument(renderChildren(root.children, ctx, 0));
    return ctx.epilogue.length ? normalizeDocument(`${body}

${ctx.epilogue.join("\n\n")}`) : body;
  }
  function buildHandlerContext(node, ctx, depth) {
    return {
      options: ctx.options,
      inline: (target) => normalizeInline(renderChildren(childrenOf(target), ctx, depth)),
      block: (target) => normalizeDocument(renderChildren(childrenOf(target), ctx, depth)),
      text: (target) => textContent(target),
      indent: (value, size) => indentContinuation(value, size),
      epilogue: (value) => {
        if (value)
          ctx.epilogue.push(value);
      }
    };
  }
  function childrenOf(node) {
    return node.type === "element" || node.type === "root" ? node.children : [];
  }
  function parseHtml(html) {
    const root = { type: "root", children: [] };
    const stack = [{ node: root, start: 0 }];
    const tokenPattern = /<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<![^>]*>|<\?[\s\S]*?\?>|<\/?[A-Za-z][^>]*>/g;
    let lastIndex = 0;
    let match;
    while ((match = tokenPattern.exec(html)) !== null) {
      appendText(html.slice(lastIndex, match.index));
      const token = match[0];
      lastIndex = tokenPattern.lastIndex;
      if (token.startsWith("<!--")) {
        current().children.push({ type: "comment", value: token });
        continue;
      }
      if (/^<\//.test(token)) {
        const tag2 = token.slice(2, -1).trim().toLowerCase();
        closeTag(tag2, tokenPattern.lastIndex);
        continue;
      }
      const open = /^<([A-Za-z][^\s/>]*)([\s\S]*?)\/?>$/.exec(token);
      if (!open) {
        appendText(token);
        continue;
      }
      const tag = open[1].toLowerCase();
      const element = {
        type: "element",
        tag,
        attrs: parseAttrs(open[2] ?? ""),
        children: [],
        raw: token
      };
      current().children.push(element);
      if (!isVoidTag(tag) && !/\/>$/.test(token)) {
        stack.push({ node: element, start: match.index });
      } else {
        element.raw = html.slice(match.index, tokenPattern.lastIndex);
      }
    }
    appendText(html.slice(lastIndex));
    for (let index = 1; index < stack.length; index += 1) {
      const entry = stack[index];
      if (entry.node.type === "element") {
        entry.node.raw = html.slice(entry.start);
      }
    }
    return root;
    function current() {
      return stack[stack.length - 1].node;
    }
    function appendText(value) {
      if (value)
        current().children.push({ type: "text", value });
    }
    function closeTag(tag, end) {
      for (let index = stack.length - 1; index > 0; index -= 1) {
        const entry = stack[index];
        if (entry.node.type === "element" && entry.node.tag === tag) {
          entry.node.raw = html.slice(entry.start, end);
          stack.length = index;
          return;
        }
      }
      appendText(html.slice(end - tag.length - 3, end));
    }
  }
  function parseAttrs(input) {
    const attrs = {};
    const attrPattern = /([^\s"'=<>`]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
    let match;
    while ((match = attrPattern.exec(input)) !== null) {
      attrs[match[1].toLowerCase()] = decodeEntities(match[2] ?? match[3] ?? match[4] ?? "");
    }
    return attrs;
  }
  function hasUnsupportedAttrs(node) {
    const names = Object.keys(node.attrs);
    if (names.length === 0)
      return false;
    if (node.tag === "a")
      return names.some((name) => name !== "href" && name !== "title");
    if (node.tag === "img")
      return names.some((name) => name !== "src" && name !== "alt" && name !== "title");
    if (node.tag === "ol")
      return names.some((name) => name !== "start");
    if (node.tag === "code" || node.tag === "pre") {
      return names.some((name) => name !== "class") || !/\blanguage-[A-Za-z0-9_-]+/.test(node.attrs.class ?? "");
    }
    if (/^h[1-6]$/.test(node.tag)) {
      return names.some((name) => {
        if (name !== "id")
          return true;
        return node.attrs.id !== slugifyText(textContent(node));
      });
    }
    return true;
  }
  function slugifyText(value) {
    return value.toLowerCase().replace(/[^\w\s-]/g, "").replace(/[\s_]+/g, "-").replace(/^-+|-+$/g, "");
  }
  function renderChildren(nodes, ctx, depth) {
    return nodes.map((node) => renderNode(node, ctx, depth)).join("");
  }
  function renderNode(node, ctx, depth) {
    if (node.type === "text")
      return collapseText(decodeEntities(node.value));
    if (node.type === "comment")
      return ctx.options.unsupported === "preserve" ? node.value : " ";
    if (node.type === "root")
      return renderChildren(node.children, ctx, depth);
    const inline = () => normalizeInline(renderChildren(node.children, ctx, depth));
    const block = () => normalizeDocument(renderChildren(node.children, ctx, depth));
    for (const handler of ctx.handlers) {
      const result = handler(node, buildHandlerContext(node, ctx, depth));
      if (result !== void 0) {
        return blockTags.has(node.tag) ? blockWrap(result) : result;
      }
    }
    if (ctx.options.unsupported === "preserve" && hasUnsupportedAttrs(node)) {
      return blockTags.has(node.tag) ? blockWrap(node.raw) : node.raw;
    }
    if (/^h[1-6]$/.test(node.tag))
      return blockWrap(`${"#".repeat(Number(node.tag[1]))} ${inline()}`);
    if (node.tag === "p")
      return blockWrap(normalizeParagraph(renderChildren(node.children, ctx, depth)));
    if (node.tag === "br")
      return "  \n";
    if (node.tag === "hr")
      return blockWrap("---");
    if (node.tag === "strong" || node.tag === "b")
      return inlineWrap("**", inline());
    if (node.tag === "em" || node.tag === "i")
      return inlineWrap("*", inline());
    if (node.tag === "del" || node.tag === "s" || node.tag === "strike")
      return inlineWrap("~~", inline());
    if (node.tag === "code")
      return renderInlineCode(textContent(node));
    if (node.tag === "pre")
      return blockWrap(renderCodeBlock(node));
    if (node.tag === "a")
      return renderLink(node, inline());
    if (node.tag === "img")
      return renderImage(node);
    if (node.tag === "blockquote")
      return blockWrap(prefixLines(block(), "> "));
    if (node.tag === "ul" || node.tag === "ol")
      return blockWrap(renderList(node, ctx, depth));
    if (node.tag === "li")
      return inline();
    if (node.tag === "table") {
      if (ctx.options.unsupported === "preserve" && tableHasUnsupportedStructure(node))
        return blockWrap(node.raw);
      return blockWrap(renderTable(node, ctx));
    }
    if (node.tag === "thead" || node.tag === "tbody" || node.tag === "tr" || node.tag === "th" || node.tag === "td")
      return inline();
    if (node.tag === "div" || node.tag === "section" || node.tag === "article" || node.tag === "main" || node.tag === "header" || node.tag === "footer" || node.tag === "nav")
      return blockWrap(block());
    if (node.tag === "span")
      return inline();
    if (passthroughInlineTags.has(node.tag) || blockTags.has(node.tag)) {
      return ctx.options.unsupported === "preserve" ? node.raw : block();
    }
    return ctx.options.unsupported === "preserve" ? node.raw : inline();
  }
  function renderLink(node, text) {
    const href = node.attrs.href;
    if (!href)
      return text;
    const title = node.attrs.title ? ` "${escapeTitle(node.attrs.title)}"` : "";
    return `[${escapeLinkText(text)}](${escapeUrl(href)}${title})`;
  }
  function renderImage(node) {
    const src = node.attrs.src;
    if (!src)
      return "";
    const alt = escapeLinkText(node.attrs.alt ?? "");
    const title = node.attrs.title ? ` "${escapeTitle(node.attrs.title)}"` : "";
    return `![${alt}](${escapeUrl(src)}${title})`;
  }
  function renderInlineCode(value) {
    const ticks = longestRun(value, "`") + 1;
    const fence = "`".repeat(Math.max(1, ticks));
    const padding = value.startsWith("`") || value.endsWith("`") ? " " : "";
    return `${fence}${padding}${value}${padding}${fence}`;
  }
  function renderCodeBlock(node) {
    const codeElement = node.children.find((child) => child.type === "element" && child.tag === "code");
    const className = codeElement?.attrs.class ?? node.attrs.class ?? "";
    const lang = /\blanguage-([A-Za-z0-9_-]+)/.exec(className)?.[1] ?? "";
    const code = textContent(codeElement ?? node).replace(/\n$/, "");
    const fence = "`".repeat(Math.max(3, longestRun(code, "`") + 1));
    return `${fence}${lang}
${code}
${fence}`;
  }
  function renderList(node, ctx, depth) {
    return node.children.filter((child) => child.type === "element" && child.tag === "li").map((item, index) => {
      const marker = node.tag === "ol" ? `${Number(node.attrs.start ?? 1) + index}. ` : "- ";
      const body = normalizeListItemBody(renderChildren(item.children, ctx, depth + 1));
      return indentContinuation(`${marker}${body}`, marker.length);
    }).join("\n");
  }
  function renderTable(node, ctx) {
    const rows = collectRows(node).map((row) => row.children.filter((cell) => cell.type === "element" && (cell.tag === "th" || cell.tag === "td"))).filter((row) => row.length > 0);
    if (rows.length === 0)
      return "";
    const width = Math.max(...rows.map((row) => row.length));
    const values = rows.map((row) => Array.from({ length: width }, (_, index) => normalizeInline(renderChildren(row[index]?.children ?? [], ctx, 0))));
    const header = values[0];
    const separator = Array.from({ length: width }, () => "---");
    const body = values.slice(1);
    return [header, separator, ...body].map((row) => `| ${row.join(" | ")} |`).join("\n");
  }
  function tableHasUnsupportedStructure(node) {
    return collectRows(node).some((row) => row.children.some((cell) => cell.type === "element" && (cell.tag === "th" || cell.tag === "td") && Object.keys(cell.attrs).length > 0));
  }
  function collectRows(node) {
    const rows = [];
    for (const child of node.children) {
      if (child.type !== "element")
        continue;
      if (child.tag === "tr")
        rows.push(child);
      if (child.tag === "thead" || child.tag === "tbody" || child.tag === "tfoot")
        rows.push(...collectRows(child));
    }
    return rows;
  }
  function textContent(node) {
    if (node.type === "text")
      return decodeEntities(node.value);
    if ("children" in node)
      return node.children.map(textContent).join("");
    return "";
  }
  function inlineWrap(marker, value) {
    return value ? `${marker}${value}${marker}` : "";
  }
  function blockWrap(value) {
    const trimmed = value.trim();
    return trimmed ? `

${trimmed}

` : "";
  }
  function normalizeDocument(value) {
    return value.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  }
  function normalizeInline(value) {
    return value.replace(/[ \t\r\n]+/g, " ").trim();
  }
  function normalizeParagraph(value) {
    return value.split("\n").map((line) => normalizeInline(line)).join("\n").replace(/ *  \n */g, "  \n").trim();
  }
  function normalizeListItemBody(value) {
    return normalizeDocument(value).replace(/\n\n(?=(?:[-*+]|\d+[.)]) )/g, "\n");
  }
  function collapseText(value) {
    return value.replace(/\s+/g, " ");
  }
  function prefixLines(value, prefix) {
    return value.split("\n").map((line) => line ? `${prefix}${line}` : prefix.trimEnd()).join("\n");
  }
  function indentContinuation(value, size) {
    const indent = " ".repeat(size);
    return value.split("\n").map((line, index) => index === 0 ? line : `${indent}${line}`).join("\n");
  }
  function isVoidTag(tag) {
    return /^(area|base|br|col|embed|hr|img|input|link|meta|param|source|track|wbr)$/.test(tag);
  }
  function decodeEntities(value) {
    return value.replace(/&#x([0-9a-f]+);?/gi, (_, hex) => String.fromCodePoint(Number.parseInt(hex, 16))).replace(/&#([0-9]+);?/g, (_, decimal) => String.fromCodePoint(Number.parseInt(decimal, 10))).replace(/&([a-z]+);/gi, (entity, name) => namedEntities[name.toLowerCase()] ?? entity);
  }
  var namedEntities = {
    amp: "&",
    apos: "'",
    gt: ">",
    lt: "<",
    nbsp: " ",
    quot: '"'
  };
  function escapeLinkText(value) {
    return value.replace(/([\\\]])/g, "\\$1");
  }
  function escapeTitle(value) {
    return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  }
  function escapeUrl(value) {
    return value.replace(/\s/g, "%20").replace(/\)/g, "%29");
  }
  function longestRun(value, char) {
    let longest = 0;
    let current = 0;
    for (const part of value) {
      if (part === char) {
        current += 1;
        longest = Math.max(longest, current);
      } else {
        current = 0;
      }
    }
    return longest;
  }
  var htmlChildElements = (node) => node.type === "element" || node.type === "root" ? node.children.filter((child) => child.type === "element") : [];
  var findHtmlElement = (node, predicate) => htmlChildElements(node).find(predicate);
  var hasHtmlClass = (node, className) => node.type === "element" && (node.attrs.class ?? "").split(/\s+/).includes(className);
  var findHtmlDescendant = (node, predicate) => {
    for (const child of htmlChildElements(node)) {
      if (predicate(child))
        return child;
      const nested = findHtmlDescendant(child, predicate);
      if (nested)
        return nested;
    }
    return void 0;
  };
  var htmlRoot = (children) => ({ type: "root", children });

  // ../nizel/dist/collect.js
  function collect(ast) {
    const headings = [];
    const links = [];
    const images = [];
    const text = blockText(ast.children, { headings, links, images }).trim();
    const words = text ? text.split(/\s+/).length : 0;
    return {
      text,
      headings,
      links,
      images,
      excerpt: text ? text.slice(0, 160).trim() : void 0,
      readingTime: {
        words,
        minutes: Math.max(1, Math.ceil(words / 200))
      }
    };
  }
  function blockText(nodes, state) {
    return nodes.map((node) => {
      if (node.type === "heading") {
        const text = inlineText(node.children, state);
        state.headings.push({
          id: node.id ?? "",
          slug: node.id ?? "",
          text,
          depth: node.depth,
          level: node.depth
        });
        return text;
      }
      if (node.type === "paragraph")
        return inlineText(node.children, state);
      if (node.type === "code")
        return node.code;
      if (node.type === "list") {
        return node.children.map((item) => blockText(item.children, state)).join("\n");
      }
      if (node.type === "blockquote")
        return blockText(node.children, state);
      if (node.type === "table") {
        return node.children.map((row) => row.children.map((cell) => inlineText(cell.children, state)).join("	")).join("\n");
      }
      if (node.type === "html")
        return node.value;
      if (node.type === "customBlock")
        return nestedText(node.children ?? [], state);
      return "";
    }).filter(Boolean).join("\n");
  }
  function inlineText(nodes, state) {
    if (nodes.length === 0)
      return "";
    if (nodes.length === 1)
      return inlineNodeText(nodes[0], state);
    return nodes.map((node) => inlineNodeText(node, state)).join("");
  }
  function inlineNodeText(node, state) {
    if (node.type === "text")
      return node.value;
    if (node.type === "inlineHtml")
      return "";
    if (node.type === "lineBreak")
      return " ";
    if (node.type === "inlineCode")
      return node.code;
    if (node.type === "image") {
      state.images.push({
        src: node.src,
        alt: node.alt,
        title: node.title
      });
      return node.alt ?? "";
    }
    if (node.type === "link") {
      const text = inlineText(node.children, state);
      state.links.push({
        href: node.href,
        text,
        title: node.title,
        external: Boolean(node.external)
      });
      return text;
    }
    return inlineText(node.children, state);
  }
  function nestedText(nodes, state) {
    return nodes.map((node) => {
      if (node.type === "root")
        return blockText(node.children, state);
      if (isBlock(node))
        return blockText([node], state);
      if (isInline(node))
        return inlineText([node], state);
      if (node.type === "listItem")
        return blockText(node.children, state);
      if (node.type === "tableRow") {
        return node.children.map((cell) => inlineText(cell.children, state)).join("	");
      }
      if (node.type === "tableCell")
        return inlineText(node.children, state);
      return "";
    }).join("\n");
  }
  function isInline(node) {
    return [
      "text",
      "emphasis",
      "strong",
      "delete",
      "lineBreak",
      "inlineCode",
      "link",
      "image",
      "inlineHtml"
    ].includes(node.type);
  }
  function isBlock(node) {
    return ![
      "root",
      "text",
      "emphasis",
      "strong",
      "delete",
      "lineBreak",
      "inlineCode",
      "link",
      "image"
    ].includes(node.type);
  }

  // ../nizel/dist/frontmatter.js
  var extractFrontmatter = (markdown) => {
    if (!markdown.startsWith("---\n")) {
      return { markdown, frontmatter: {} };
    }
    const end = markdown.indexOf("\n---", 4);
    if (end === -1) {
      return { markdown, frontmatter: {} };
    }
    const raw = markdown.slice(4, end).trim();
    const rest = markdown.slice(end).replace(/^\n---\n?/, "").replace(/^\n/, "");
    return {
      markdown: rest,
      frontmatter: parseSimpleYaml(raw)
    };
  };
  var parseSimpleYaml = (raw) => {
    const result = {};
    const lines = raw.split("\n");
    let currentKey = null;
    let currentArray = null;
    for (const line of lines) {
      const listMatch = /^\s+-\s+(.*)$/.exec(line);
      if (listMatch && currentKey !== null) {
        if (!currentArray)
          currentArray = [];
        currentArray.push(parseValue(listMatch[1]));
        continue;
      }
      if (currentKey !== null && currentArray !== null) {
        result[currentKey] = currentArray;
        currentArray = null;
        currentKey = null;
      }
      const match = /^([A-Za-z0-9_-]+):\s*(.*)$/.exec(line.trim());
      if (!match)
        continue;
      const [, key, rawValue] = match;
      if (rawValue.trim() === "") {
        currentKey = key;
        currentArray = null;
      } else {
        result[key] = parseValue(rawValue);
        currentKey = null;
      }
    }
    if (currentKey !== null && currentArray !== null) {
      result[currentKey] = currentArray;
    }
    return result;
  };
  var parseValue = (value) => {
    const trimmed = value.trim();
    if (trimmed === "true")
      return true;
    if (trimmed === "false")
      return false;
    if (trimmed === "null")
      return null;
    if (/^-?\d+(\.\d+)?$/.test(trimmed))
      return Number(trimmed);
    return trimmed.replace(/^["']|["']$/g, "");
  };

  // ../../node_modules/@sil/case/dist/index.mjs
  var h = { a: ["\xE4", "\xE1", "\xE0", "\xE2", "\xE3", "\u0101", "\u01CE", "\xE5", "\u0103", "\u0105", "\u01DF", "\u01E1", "\u01FB", "\u0201", "\u0203", "\u0227", "\u1EA1", "\u1EA3", "\u1EA5", "\u1EA7", "\u1EA9", "\u1EAB", "\u1EAD", "\u1EAF", "\u1EB1", "\u1EB3", "\u1EB5", "\u1EB7"], b: ["\xDF", "\u0180", "\u0183", "\u0253", "\u1D6C", "\u1D80", "\u1E03", "\u1E05", "\u1E07"], c: ["\u0107", "\u010D", "\xE7", "\u0109", "\u010B", "\u0188", "\u023C", "\u0255", "\u1E09"], d: ["\u0111", "\u010F", "\u1E0B", "\u1E0D", "\u1E0F", "\u1E11", "\u1E13"], e: ["\xEB", "\xE9", "\xE8", "\xEA", "\u0113", "\u011B", "\u0117", "\u0119", "\u01DD", "\u0205", "\u0207", "\u0229", "\u025B", "\u0258", "\u1EB9", "\u1EBB", "\u1EBD", "\u1EBF", "\u1EC1", "\u1EC3", "\u1EC5", "\u1EC7"], f: ["\u0192", "\u1E1F"], g: ["\u011F", "\u011D", "\u0121", "\u0123", "\u01E7", "\u01F5", "\u0260", "\u1E21", "\u1D79"], h: ["\u0125", "\u021F", "\u1E29", "\u1E25", "\u1E2B", "\u1E96", "\u0127", "\u2C68", "\u0266"], i: ["\xEF", "\xED", "\xEC", "\xEE", "\u012B", "\u01D0", "\u012F", "\u0131", "\u0268", "\u1EC9", "\u1ECB", "\u026A", "\u0269"], j: ["\u0135", "\u01F0", "\u0237"], k: ["\u0137", "\u0199", "\u1E33", "\u1E35", "\u2C6A"], l: ["\u0142", "\u013A", "\u013E", "\u013C", "\u0140", "\u1E37", "\u1E39", "\u1E3B", "\u1E3D", "\u0234"], m: ["\u1E41", "\u1E43", "\u1D6F", "\u0271", "\u1D86", "\u1E3F", "\u1E41", "\u1E43", "\u1E47", "\u1E45", "\u1E49", "\u1E4B"], n: ["\xF1", "\u0144", "\u01F9", "\u0148", "\u0146", "\u014B", "\u0272", "\u1E45", "\u1E47", "\u1E49", "\u1E4B", "\u207F"], o: ["\xF6", "\xF3", "\xF2", "\xF4", "\xF5", "\u014D", "\u01D2", "\xF8", "\u0151", "\u01A1", "\u01EB", "\u020D", "\u020F", "\u022B", "\u022D", "\u022F", "\u1ECD", "\u1ECF", "\u1ED1", "\u1ED3", "\u1ED5", "\u1ED7", "\u1ED9", "\u1EDB", "\u1EDD", "\u1EDF", "\u1EE1", "\u1EE3"], p: ["\xFE", "\u01A5", "\u1D7D", "\u1D88", "\u1E57"], q: ["\u02A0", "\u024B"], r: ["\u0159", "\u0155", "\u1E59", "\u1E5B", "\u1E5D", "\u1E5F"], s: ["\u015B", "\u0161", "\u015F", "\u015D", "\u0219", "\u1E61", "\u1E63", "\u1E65", "\u1E67", "\u1E69"], t: ["\u0163", "\u0165", "\u1E6B", "\u1E6D", "\u1E6F", "\u1E71", "\u1E97", "\u01AD", "\u0236"], u: ["\xFC", "\xFA", "\xF9", "\xFB", "\u016B", "\u01D4", "\u016F", "\u0171", "\u0173", "\u01B0", "\u01D8", "\u01DC", "\u01D6", "\u01DA", "\u0215", "\u0217", "\u1EE5", "\u1EE7", "\u1EE9", "\u1EEB", "\u1EED", "\u1EEF", "\u1EF1"], v: ["\u028B", "\u1E7F", "\u2C71", "\u028C"], w: ["\u1E85", "\u1E83", "\u1E81", "\u0175", "\u1E87", "\u1E89", "\u2C73", "\u1E98"], x: ["\u1E8D", "\u1E8B", "\u2093", "\u2715"], y: ["\xFF", "\xFD", "\u1EF3", "\u0177", "\xFF", "\u1EF9", "\u0233", "\u024F", "\u01B4", "\u028E", "\u1E99", "\u1EF7", "\u1EF5"], z: ["\u017E", "\u017A", "\u017C", "\u1E91", "\u1E93", "\u1E95"] };
  var A = (e) => e === e.toUpperCase();
  var u = (e, t) => e.split("").map((s) => {
    if (t && t.has(s)) return s;
    if (!s.match(/([a-zA-Z0-9 -])/g)) {
      let a = Object.keys(h).find((o) => h[o].indexOf(s.toLowerCase()) > -1) || "_";
      return A(s) ? a.toUpperCase() : a;
    }
    return s;
  }).join("");
  var $ = (e, t = {}) => {
    if (!e) return "";
    let r = t.exclude ? new Set(t.exclude) : void 0, n = u(e, r);
    if (t.exclude && t.exclude.length > 0) {
      let l = e.split(/[-_\s]+/), c = "";
      for (let i = 0; i < l.length; i++) {
        let x = l[i];
        if (!x) continue;
        let f = "", w = c === "" || i > 0;
        for (let p = 0; p < x.length; p++) {
          let d = x[p];
          if (r.has(d)) {
            if (f) {
              let S = u(f, r);
              c += w ? S.charAt(0).toUpperCase() + S.slice(1).toLowerCase() : S.toLowerCase(), f = "";
            }
            c += d, w = !/[a-zA-ZÀ-ÿ]/i.test(d);
          } else f += d;
        }
        if (f) {
          let p = u(f, r);
          c += w ? p.charAt(0).toUpperCase() + p.slice(1).toLowerCase() : p.toLowerCase();
        }
      }
      return c;
    }
    let s = "A-Za-z0-9", a = `^[^${s}]*|[^${s}]*$`, o = new RegExp(a, "g"), g = `[^${s}]+`, C = new RegExp(g, "g");
    return String(n).replace(o, "$").replace(C, "$").replace(/([a-z])([A-Z])/g, (l, c, i) => c + "$" + i).toLowerCase().replace(/(\$)(\w?)/g, (l, c, i) => i.toUpperCase());
  };
  var j = (e, t = {}) => {
    if (!e) return "";
    let r = $(e, t);
    return r.charAt(0).toLowerCase() + r.substring(1);
  };
  var L = (e = "", t = {}) => {
    if (!e) return "";
    let r = t.exclude ? new Set(t.exclude) : void 0, s = u(e, r).replace(/[-_]/g, " ");
    if (s = s.replace(/([a-z])([A-Z])/g, "$1 $2"), s = s.replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2"), t.exclude && t.exclude.length > 0) {
      let a = e.split(/[-_\s]+/), o = [];
      for (let g = 0; g < a.length; g++) {
        let C = a[g];
        if (!C) continue;
        g > 0 && o.push("-");
        let l = "";
        for (let c = 0; c < C.length; c++) {
          let i = C[c];
          if (r.has(i)) {
            if (l) {
              let x = u(l, r);
              o.push(x.toLowerCase()), l = "";
            }
            o.push(i);
          } else l += i;
        }
        if (l) {
          let c = u(l, r);
          o.push(c.toLowerCase());
        }
      }
      return o.join("");
    }
    return s.split(" ").filter((a) => a.length > 0).map((a) => a.toLowerCase()).join("-");
  };
  var m = (e, t = {}) => e ? L(e, t).replace(/-/g, "_") : "";
  var b = (e, t = {}) => {
    if (!e) return "";
    if (!t.exclude || t.exclude.length === 0) return m(e, t).toUpperCase();
    let r = new Set(t.exclude), n = m(e, t), s = "";
    for (let a = 0; a < n.length; a++) {
      let o = n[a];
      r.has(o) || r.has(o.toLowerCase()), s += o.toUpperCase();
    }
    return s;
  };
  var P = (e, t = {}) => e ? L(e, t) : "";
  var I = (e, t = {}) => {
    if (!e || !e.trim()) return "";
    let n = (t.exclude ? e : u(e)).replace(/([a-z])([A-Z])/g, "$1 $2");
    return n = n.trim(), n ? (n = n.replace(/[-_]/g, " ").toLowerCase(), n.replace(/^./, (s) => s.toUpperCase())) : "";
  };

  // ../../node_modules/@sil/format/dist/index.mjs
  var __defProp2 = Object.defineProperty;
  var __defProps = Object.defineProperties;
  var __getOwnPropDescs = Object.getOwnPropertyDescriptors;
  var __getOwnPropSymbols = Object.getOwnPropertySymbols;
  var __hasOwnProp2 = Object.prototype.hasOwnProperty;
  var __propIsEnum = Object.prototype.propertyIsEnumerable;
  var __defNormalProp = (obj, key, value) => key in obj ? __defProp2(obj, key, { enumerable: true, configurable: true, writable: true, value }) : obj[key] = value;
  var __spreadValues = (a, b2) => {
    for (var prop in b2 || (b2 = {}))
      if (__hasOwnProp2.call(b2, prop))
        __defNormalProp(a, prop, b2[prop]);
    if (__getOwnPropSymbols)
      for (var prop of __getOwnPropSymbols(b2)) {
        if (__propIsEnum.call(b2, prop))
          __defNormalProp(a, prop, b2[prop]);
      }
    return a;
  };
  var __spreadProps = (a, b2) => __defProps(a, __getOwnPropDescs(b2));
  var pad = (value) => `${value}`.padStart(2, "0");
  var flattenObject = (obj, parentKey) => {
    let result = {};
    Object.entries(obj).forEach(([key, value]) => {
      const _key = parentKey ? parentKey + "." + key : key;
      if (typeof value === "object") {
        result = __spreadValues(__spreadValues({}, result), flattenObject(value, _key));
      } else {
        result[_key] = value;
      }
    });
    return result;
  };
  var Language = {
    AM: "Armenian",
    AR: "Arabic",
    BG: "Bulgarian",
    CY: "Welsh",
    DE: "German",
    DK: "Danish",
    EN: "English",
    ES: "Spanish",
    ET: "Estonian",
    FI: "Finnish",
    FR: "French",
    GR: "Greek",
    HU: "Hungarian",
    IR: "Irish",
    IT: "Italian",
    LA: "Latvian",
    LT: "Lithuanian",
    MT: "Maltese",
    NL: "Dutch",
    NO: "Norwegian",
    PE: "Persian",
    PL: "Polish",
    PT: "Portuguese",
    RO: "Romanian",
    RU: "Russian",
    SV: "SWEDISH"
  };
  var defaultOptions = {
    language: Language.EN,
    index: -1,
    padded: false,
    template: "YY-MM-DD hh:mm:ss",
    replace: {}
  };
  var copy = {
    "month": [
      "\u0540\u0578\u0582\u0576\u057E\u0561\u0580",
      "\u0553\u0565\u057F\u0580\u057E\u0561\u0580",
      "\u0544\u0561\u0580\u057F",
      "\u0531\u057A\u0580\u056B\u056C",
      "\u0544\u0561\u0575\u056B\u057D",
      "\u0540\u0578\u0582\u0576\u056B\u057D",
      "\u0540\u0578\u0582\u056C\u056B\u057D",
      "\u0555\u0563\u0578\u057D\u057F\u0578\u057D",
      "\u054D\u0565\u057A\u057F\u0565\u0574\u0562\u0565\u0580",
      "\u0540\u0578\u056F\u057F\u0565\u0574\u0562\u0565\u0580",
      "\u0546\u0578\u0575\u0565\u0574\u0562\u0565\u0580",
      "\u0534\u0565\u056F\u057F\u0565\u0574\u0562\u0565\u0580"
    ],
    "month_short": [
      "\u0540\u0578\u0582\u0576",
      "\u0553\u0565\u057F",
      "\u0544\u0561\u0580",
      "\u0531\u057A\u0580",
      "\u0544\u0561\u0575",
      "\u0540\u0578\u0582\u0576",
      "\u0540\u0578\u0582\u056C",
      "\u0555\u0563\u057D",
      "\u054D\u0565\u057A",
      "\u0540\u0578\u056F",
      "\u0546\u0578\u0575",
      "\u0534\u0565\u056F"
    ],
    "day": [
      "\u053F\u056B\u0580\u0561\u056F\u056B",
      "\u0535\u0580\u056F\u0578\u0582\u0577\u0561\u0562\u0569\u056B",
      "\u0535\u0580\u0565\u0584\u0577\u0561\u0562\u0569\u056B",
      "\u0549\u0578\u0580\u0565\u0584\u0577\u0561\u0562\u0569\u056B",
      "\u0540\u056B\u0576\u0563\u0577\u0561\u0562\u0569\u056B",
      "\u0548\u0582\u0580\u0562\u0561\u0569",
      "\u0547\u0561\u0562\u0561\u0569"
    ],
    "day_short": [
      "\u053F\u056B\u0580",
      "\u0535\u0580\u056F",
      "\u0535\u0580\u0584",
      "\u0549\u0578\u0580",
      "\u0540\u0576\u0563",
      "\u0548\u0582\u0580\u0562",
      "\u0547\u0562\u0569"
    ],
    "ordinal": {
      "one": "{n}\u056B\u0576",
      "two": "{n}\u0580\u0564",
      "few": "{n}\u0580\u0564",
      "other": "{n}\u0580\u0564"
    }
  };
  var am_default = copy;
  var copy2 = {
    "month": [
      "\u064A\u0646\u0627\u064A\u0631",
      "\u0641\u0628\u0631\u0627\u064A\u0631",
      "\u0645\u0627\u0631\u0633",
      "\u0623\u0628\u0631\u064A\u0644",
      "\u0645\u0627\u064A\u0648",
      "\u064A\u0648\u0646\u064A\u0648",
      "\u064A\u0648\u0644\u064A\u0648",
      "\u0623\u063A\u0633\u0637\u0633",
      "\u0633\u0628\u062A\u0645\u0628\u0631",
      "\u0623\u0643\u062A\u0648\u0628\u0631",
      "\u0646\u0648\u0641\u0645\u0628\u0631",
      "\u062F\u064A\u0633\u0645\u0628\u0631"
    ],
    "month_short": [
      "\u064A\u0646\u0627",
      "\u0641\u0628\u0631",
      "\u0645\u0627\u0631",
      "\u0623\u0628\u0631",
      "\u0645\u0627\u064A",
      "\u064A\u0648\u0646",
      "\u064A\u0648\u0644",
      "\u0623\u063A\u0633",
      "\u0633\u0628\u062A",
      "\u0623\u0643\u062A",
      "\u0646\u0648\u0641",
      "\u062F\u064A\u0633"
    ],
    "day": [
      "\u0627\u0644\u0623\u062D\u062F",
      "\u0627\u0644\u0627\u062B\u0646\u064A\u0646",
      "\u0627\u0644\u062B\u0644\u0627\u062B\u0627\u0621",
      "\u0627\u0644\u0623\u0631\u0628\u0639\u0627\u0621",
      "\u0627\u0644\u062E\u0645\u064A\u0633",
      "\u0627\u0644\u062C\u0645\u0639\u0629",
      "\u0627\u0644\u0633\u0628\u062A"
    ],
    "day_short": [
      "\u0627\u0644\u0623\u062D",
      "\u0627\u0644\u0627\u062B",
      "\u0627\u0644\u062B\u0644",
      "\u0627\u0644\u0623\u0631",
      "\u0627\u0644\u062E\u0645",
      "\u0627\u0644\u062C\u0645",
      "\u0627\u0644\u0633\u0628"
    ],
    "ordinal": {
      "one": "{n}\u0627\u0644\u0623\u0648\u0644",
      "two": "{n}\u0627\u0644\u062B\u0627\u0646\u064A",
      "few": "{n}\u0627\u0644\u062B\u0627\u0644\u062B",
      "other": "{n}\u0627\u0644\u062B\u0627\u0644\u062B"
    }
  };
  var ar_default = copy2;
  var copy3 = {
    "month": [
      "\u044F\u043D\u0443\u0430\u0440\u0438",
      "\u0444\u0435\u0432\u0440\u0443\u0430\u0440\u0438",
      "\u043C\u0430\u0440\u0442",
      "\u0430\u043F\u0440\u0438\u043B",
      "\u043C\u0430\u0439",
      "\u044E\u043D\u0438",
      "\u044E\u043B\u0438",
      "\u0430\u0432\u0433\u0443\u0441\u0442",
      "\u0441\u0435\u043F\u0442\u0435\u043C\u0432\u0440\u0438",
      "\u043E\u043A\u0442\u043E\u043C\u0432\u0440\u0438",
      "\u043D\u043E\u0435\u043C\u0432\u0440\u0438",
      "\u0434\u0435\u043A\u0435\u043C\u0432\u0440\u0438"
    ],
    "month_short": [
      "\u044F\u043D\u0443",
      "\u0444\u0435\u0432",
      "\u043C\u0430\u0440",
      "\u0430\u043F\u0440",
      "\u043C\u0430\u0439",
      "\u044E\u043D\u0438",
      "\u044E\u043B\u0438",
      "\u0430\u0432\u0433",
      "\u0441\u0435\u043F",
      "\u043E\u043A\u0442",
      "\u043D\u043E\u0435",
      "\u0434\u0435\u043A"
    ],
    "day": [
      "\u043D\u0435\u0434\u0435\u043B\u044F",
      "\u043F\u043E\u043D\u0435\u0434\u0435\u043B\u043D\u0438\u043A",
      "\u0432\u0442\u043E\u0440\u043D\u0438\u043A",
      "\u0441\u0440\u044F\u0434\u0430",
      "\u0447\u0435\u0442\u0432\u044A\u0440\u0442\u044A\u043A",
      "\u043F\u0435\u0442\u044A\u043A",
      "\u0441\u044A\u0431\u043E\u0442\u0430"
    ],
    "day_short": [
      "\u043D\u0435\u0434",
      "\u043F\u043E\u043D",
      "\u0432\u0442\u043E",
      "\u0441\u0440\u044F",
      "\u0447\u0435\u0442",
      "\u043F\u0435\u0442",
      "\u0441\u044A\u0431"
    ],
    ordinal: {
      one: "\u0432\u0438",
      two: "\u0440\u0438",
      few: "\u0442\u0438",
      other: "\u0442\u0438"
    }
  };
  var bg_default = copy3;
  var copy4 = {
    "month": [
      "Ionawr",
      "Chwefror",
      "Mawrth",
      "Ebrill",
      "Mai",
      "Mehefin",
      "Gorffennaf",
      "Awst",
      "Medi",
      "Hydref",
      "Tachwedd",
      "Rhagfyr"
    ],
    "month_short": [
      "Ion",
      "Chwef",
      "Maw",
      "Ebr",
      "Mai",
      "Meh",
      "Gorff",
      "Awst",
      "Medi",
      "Hyd",
      "Tach",
      "Rhag"
    ],
    "day": [
      "Dydd Sul",
      "Dydd Llun",
      "Dydd Mawrth",
      "Dydd Mercher",
      "Dydd Iau",
      "Dydd Gwener",
      "Dydd Sadwrn"
    ],
    "day_short": [
      "Sul",
      "Llun",
      "Maw",
      "Mer",
      "Iau",
      "Gwen",
      "Sad"
    ],
    "ordinal": {
      "one": "{n}fed",
      "two": "{n}fed",
      "few": "{n}ydd",
      "other": "{n}ed"
    }
  };
  var cy_default = copy4;
  var copy5 = {
    month: [
      "Januar",
      "Februar",
      "M\xE4rz",
      "April",
      "Mai",
      "Juni",
      "Juli",
      "August",
      "September",
      "Oktober",
      "November",
      "Dezember"
    ],
    month_short: [
      "Jan",
      "Feb",
      "M\xE4r",
      "Apr",
      "Mai",
      "Jun",
      "Jul",
      "Aug",
      "Sep",
      "Okt",
      "Nov",
      "Dez"
    ],
    day: [
      "Sonntag",
      "Montag",
      "Dienstag",
      "Mittwoch",
      "Donnerstag",
      "Freitag",
      "Samstag"
    ],
    day_short: [
      "So",
      "Mo",
      "Di",
      "Mi",
      "Do",
      "Fr",
      "Sa"
    ],
    ordinal: {
      "one": "{n}ste",
      "two": "{n}de",
      "few": "{n}de",
      "other": "{n}de"
    }
  };
  var de_default = copy5;
  var copy6 = {
    "month": [
      "januar",
      "februar",
      "marts",
      "april",
      "maj",
      "juni",
      "juli",
      "august",
      "september",
      "oktober",
      "november",
      "december"
    ],
    "month_short": [
      "jan",
      "feb",
      "mar",
      "apr",
      "maj",
      "jun",
      "jul",
      "aug",
      "sep",
      "okt",
      "nov",
      "dec"
    ],
    "day": [
      "s\xF8ndag",
      "mandag",
      "tirsdag",
      "onsdag",
      "torsdag",
      "fredag",
      "l\xF8rdag"
    ],
    "day_short": [
      "s\xF8n",
      "man",
      "tir",
      "ons",
      "tor",
      "fre",
      "l\xF8r"
    ],
    "ordinal": {
      "one": "{n}st",
      "two": "{n}nd",
      "few": "{n}rd",
      "other": "{n}th"
    }
  };
  var dk_default = copy6;
  var copy7 = {
    month: [
      "January",
      "February",
      "March",
      "April",
      "May",
      "June",
      "July",
      "August",
      "September",
      "October",
      "November",
      "December"
    ],
    month_short: [
      "jan",
      "feb",
      "mar",
      "apr",
      "may",
      "jun",
      "jul",
      "aug",
      "sep",
      "oct",
      "nov",
      "dec"
    ],
    day: [
      "Sunday",
      "Monday",
      "Tuesday",
      "Wednesday",
      "Thursday",
      "Friday",
      "Saturday"
    ],
    day_short: ["sun", "mon", "tue", "wed", "thu", "fri", "sat"],
    ordinal: {
      one: "{n}st",
      two: "{n}nd",
      few: "{n}rd",
      other: "{n}th"
    }
  };
  var en_default = copy7;
  var copy8 = {
    "month": [
      "enero",
      "febrero",
      "marzo",
      "abril",
      "mayo",
      "junio",
      "julio",
      "agosto",
      "septiembre",
      "octubre",
      "noviembre",
      "diciembre"
    ],
    "month_short": [
      "ene",
      "feb",
      "mar",
      "abr",
      "may",
      "jun",
      "jul",
      "ago",
      "sep",
      "oct",
      "nov",
      "dic"
    ],
    "day": [
      "domingo",
      "lunes",
      "martes",
      "mi\xE9rcoles",
      "jueves",
      "viernes",
      "s\xE1bado"
    ],
    "day_short": [
      "dom",
      "lun",
      "mar",
      "mi\xE9",
      "jue",
      "vie",
      "s\xE1b"
    ],
    "ordinal": {
      "one": "{n}ro",
      "two": "{n}do",
      "few": "{n}ro",
      "other": "{n}to"
    }
  };
  var es_default = copy8;
  var copy9 = {
    "month": [
      "jaanuar",
      "veebruar",
      "m\xE4rts",
      "aprill",
      "mai",
      "juuni",
      "juuli",
      "august",
      "september",
      "oktoober",
      "november",
      "detsember"
    ],
    "month_short": [
      "jaan",
      "veebr",
      "m\xE4rts",
      "apr",
      "mai",
      "juuni",
      "juuli",
      "aug",
      "sept",
      "okt",
      "nov",
      "dets"
    ],
    "day": [
      "p\xFChap\xE4ev",
      "esmasp\xE4ev",
      "teisip\xE4ev",
      "kolmap\xE4ev",
      "neljap\xE4ev",
      "reede",
      "laup\xE4ev"
    ],
    "day_short": [
      "P",
      "E",
      "T",
      "K",
      "N",
      "R",
      "L"
    ],
    "ordinal": {
      "one": "{n}esimene",
      "two": "{n}teine",
      "few": "{n}kolmas",
      "other": "{n}esimene"
    }
  };
  var et_default = copy9;
  var copy10 = {
    "month": [
      "tammikuu",
      "helmikuu",
      "maaliskuu",
      "huhtikuu",
      "toukokuu",
      "kes\xE4kuu",
      "hein\xE4kuu",
      "elokuu",
      "syyskuu",
      "lokakuu",
      "marraskuu",
      "joulukuu"
    ],
    "month_short": [
      "tammi",
      "helmi",
      "maalis",
      "huhti",
      "touko",
      "kes\xE4",
      "hein\xE4",
      "elo",
      "syys",
      "loka",
      "marras",
      "joulu"
    ],
    "day": [
      "sunnuntai",
      "maanantai",
      "tiistai",
      "keskiviikko",
      "torstai",
      "perjantai",
      "lauantai"
    ],
    "day_short": [
      "su",
      "ma",
      "ti",
      "ke",
      "to",
      "pe",
      "la"
    ],
    "ordinal": {
      "one": "{n}ensimm\xE4inen",
      "two": "{n}toinen",
      "few": "{n}kolmas",
      "other": "{n}kolmas"
    }
  };
  var fi_default = copy10;
  var copy11 = {
    "month": [
      "janvier",
      "f\xE9vrier",
      "mars",
      "avril",
      "mai",
      "juin",
      "juillet",
      "ao\xFBt",
      "septembre",
      "octobre",
      "novembre",
      "d\xE9cembre"
    ],
    "month_short": [
      "janv",
      "f\xE9vr",
      "mars",
      "avr",
      "mai",
      "juin",
      "juil",
      "ao\xFBt",
      "sept",
      "oct",
      "nov",
      "d\xE9c"
    ],
    "day": [
      "dimanche",
      "lundi",
      "mardi",
      "mercredi",
      "jeudi",
      "vendredi",
      "samedi"
    ],
    "day_short": [
      "dim",
      "lun",
      "mar",
      "mer",
      "jeu",
      "ven",
      "sam"
    ],
    "ordinal": {
      "one": "{n}er",
      "two": "{n}do",
      "few": "{n}do",
      "other": "{n}to"
    }
  };
  var fr_default = copy11;
  var copy12 = {
    "month": [
      "\u0399\u03B1\u03BD\u03BF\u03C5\u03AC\u03C1\u03B9\u03BF\u03C2",
      "\u03A6\u03B5\u03B2\u03C1\u03BF\u03C5\u03AC\u03C1\u03B9\u03BF\u03C2",
      "\u039C\u03AC\u03C1\u03C4\u03B9\u03BF\u03C2",
      "\u0391\u03C0\u03C1\u03AF\u03BB\u03B9\u03BF\u03C2",
      "\u039C\u03AC\u03B9\u03BF\u03C2",
      "\u0399\u03BF\u03CD\u03BD\u03B9\u03BF\u03C2",
      "\u0399\u03BF\u03CD\u03BB\u03B9\u03BF\u03C2",
      "\u0391\u03CD\u03B3\u03BF\u03C5\u03C3\u03C4\u03BF\u03C2",
      "\u03A3\u03B5\u03C0\u03C4\u03AD\u03BC\u03B2\u03C1\u03B9\u03BF\u03C2",
      "\u039F\u03BA\u03C4\u03CE\u03B2\u03C1\u03B9\u03BF\u03C2",
      "\u039D\u03BF\u03AD\u03BC\u03B2\u03C1\u03B9\u03BF\u03C2",
      "\u0394\u03B5\u03BA\u03AD\u03BC\u03B2\u03C1\u03B9\u03BF\u03C2"
    ],
    "month_short": [
      "\u0399\u03B1\u03BD",
      "\u03A6\u03B5\u03B2",
      "\u039C\u03AC\u03C1",
      "\u0391\u03C0\u03C1",
      "\u039C\u03AC\u03B9",
      "\u0399\u03BF\u03CD\u03BD",
      "\u0399\u03BF\u03CD\u03BB",
      "\u0391\u03CD\u03B3",
      "\u03A3\u03B5\u03C0",
      "\u039F\u03BA\u03C4",
      "\u039D\u03BF\u03AD",
      "\u0394\u03B5\u03BA"
    ],
    "day": [
      "\u039A\u03C5\u03C1\u03B9\u03B1\u03BA\u03AE",
      "\u0394\u03B5\u03C5\u03C4\u03AD\u03C1\u03B1",
      "\u03A4\u03C1\u03AF\u03C4\u03B7",
      "\u03A4\u03B5\u03C4\u03AC\u03C1\u03C4\u03B7",
      "\u03A0\u03AD\u03BC\u03C0\u03C4\u03B7",
      "\u03A0\u03B1\u03C1\u03B1\u03C3\u03BA\u03B5\u03C5\u03AE",
      "\u03A3\u03AC\u03B2\u03B2\u03B1\u03C4\u03BF"
    ],
    "day_short": [
      "\u039A\u03C5\u03C1",
      "\u0394\u03B5\u03C5",
      "\u03A4\u03C1\u03B9",
      "\u03A4\u03B5\u03C4",
      "\u03A0\u03B5\u03BC",
      "\u03A0\u03B1\u03C1",
      "\u03A3\u03B1\u03B2"
    ],
    "ordinal": {
      "one": "{n}\u03B7",
      "two": "{n}\u03B7",
      "few": "{n}\u03B7",
      "other": "{n}\u03B7"
    }
  };
  var gr_default = copy12;
  var copy13 = {
    "month": [
      "janu\xE1r",
      "febru\xE1r",
      "m\xE1rcius",
      "\xE1prilis",
      "m\xE1jus",
      "j\xFAnius",
      "j\xFAlius",
      "augusztus",
      "szeptember",
      "okt\xF3ber",
      "november",
      "december"
    ],
    "month_short": [
      "jan",
      "feb",
      "m\xE1r",
      "\xE1pr",
      "m\xE1j",
      "j\xFAn",
      "j\xFAl",
      "aug",
      "szept",
      "okt",
      "nov",
      "dec"
    ],
    "day": [
      "vas\xE1rnap",
      "h\xE9tf\u0151",
      "kedd",
      "szerda",
      "cs\xFCt\xF6rt\xF6k",
      "p\xE9ntek",
      "szombat"
    ],
    "day_short": [
      "v",
      "h",
      "k",
      "sze",
      "cs",
      "p",
      "szo"
    ],
    "ordinal": {
      "one": "{n}ik",
      "two": "{n}ik",
      "few": "{n}ik",
      "other": "{n}ik"
    }
  };
  var hu_default = copy13;
  var copy14 = {
    "month": [
      "Ean\xE1ir",
      "Feabhra",
      "M\xE1rta",
      "Aibre\xE1n",
      "Bealtaine",
      "Meitheamh",
      "I\xFAil",
      "L\xFAnasa",
      "Me\xE1n F\xF3mhair",
      "Deireadh F\xF3mhair",
      "Samhain",
      "Nollaig"
    ],
    "month_short": [
      "Ean",
      "Feabh",
      "M\xE1r",
      "Aib",
      "Beal",
      "Meith",
      "I\xFAil",
      "L\xFAn",
      "MF\xF3mh",
      "DF\xF3mh",
      "Samh",
      "Noll"
    ],
    "day": [
      "D\xE9 Domhnaigh",
      "D\xE9 Luain",
      "D\xE9 M\xE1irt",
      "D\xE9 C\xE9adaoin",
      "D\xE9ardaoin",
      "D\xE9 hAoine",
      "D\xE9 Sathairn"
    ],
    "day_short": [
      "Domh",
      "Luan",
      "M\xE1irt",
      "C\xE9ad",
      "D\xE9ar",
      "Aoine",
      "Sath"
    ],
    "ordinal": {
      "one": "{n}\xFA",
      "two": "{n}\xFA",
      "few": "{n}\xFA",
      "other": "{n}\xFA"
    }
  };
  var ir_default = copy14;
  var copy15 = {
    "month": [
      "gennaio",
      "febbraio",
      "marzo",
      "aprile",
      "maggio",
      "giugno",
      "luglio",
      "agosto",
      "settembre",
      "ottobre",
      "novembre",
      "dicembre"
    ],
    "month_short": [
      "gen",
      "feb",
      "mar",
      "apr",
      "mag",
      "giu",
      "lug",
      "ago",
      "set",
      "ott",
      "nov",
      "dic"
    ],
    "day": [
      "domenica",
      "luned\xEC",
      "marted\xEC",
      "mercoled\xEC",
      "gioved\xEC",
      "venerd\xEC",
      "sabato"
    ],
    "day_short": [
      "dom",
      "lun",
      "mar",
      "mer",
      "gio",
      "ven",
      "sab"
    ],
    "ordinal": {
      "one": "{n}ro",
      "two": "{n}do",
      "few": "{n}ro",
      "other": "{n}to"
    }
  };
  var it_default = copy15;
  var copy16 = {
    "month": [
      "janv\u0101ris",
      "febru\u0101ris",
      "marts",
      "apr\u012Blis",
      "maijs",
      "j\u016Bnijs",
      "j\u016Blijs",
      "augusts",
      "septembris",
      "oktobris",
      "novembris",
      "decembris"
    ],
    "month_short": [
      "jan",
      "feb",
      "mar",
      "apr",
      "mai",
      "j\u016Bn",
      "j\u016Bl",
      "aug",
      "sep",
      "okt",
      "nov",
      "dec"
    ],
    "day": [
      "sv\u0113tdiena",
      "pirmdiena",
      "otrdiena",
      "tre\u0161diena",
      "ceturtdiena",
      "piektdiena",
      "sestdiena"
    ],
    "day_short": [
      "sv\u0113t",
      "pir",
      "otr",
      "tre",
      "cet",
      "pie",
      "ses"
    ],
    "ordinal": {
      "one": "{n}ais",
      "two": "{n}ais",
      "few": "{n}ais",
      "other": "{n}ais"
    }
  };
  var la_default = copy16;
  var copy17 = {
    "month": [
      "sausis",
      "vasaris",
      "kovas",
      "balandis",
      "gegu\u017E\u0117",
      "bir\u017Eelis",
      "liepa",
      "rugpj\u016Btis",
      "rugs\u0117jis",
      "spalis",
      "lapkritis",
      "gruodis"
    ],
    "month_short": [
      "sau",
      "vas",
      "kov",
      "bal",
      "geg",
      "bir",
      "lie",
      "rugp",
      "rugs",
      "spa",
      "lap",
      "gru"
    ],
    "day": [
      "sekmadienis",
      "pirmadienis",
      "antradienis",
      "tre\u010Diadienis",
      "ketvirtadienis",
      "penktadienis",
      "\u0161e\u0161tadienis"
    ],
    "day_short": [
      "sek",
      "pir",
      "ant",
      "tre",
      "ket",
      "pen",
      "\u0161e\u0161"
    ],
    "ordinal": {
      "one": "{n}as",
      "two": "{n}as",
      "few": "{n}as",
      "other": "{n}as"
    }
  };
  var lt_default = copy17;
  var copy18 = {
    "month": [
      "Jannar",
      "Frar",
      "Marzu",
      "April",
      "Mejju",
      "\u0120unju",
      "Lulju",
      "Awissu",
      "Settembru",
      "Ottubru",
      "Novembru",
      "Di\u010Bembru"
    ],
    "month_short": [
      "Jan",
      "Fra",
      "Mar",
      "Apr",
      "Mej",
      "\u0120un",
      "Lul",
      "Awi",
      "Set",
      "Ott",
      "Nov",
      "Di\u010B"
    ],
    "day": [
      "Il-\u0126add",
      "It-Tnejn",
      "It-Tlieta",
      "L-Erbg\u0127a",
      "Il-\u0126amis",
      "Il-\u0120img\u0127a",
      "Is-Sibt"
    ],
    "day_short": [
      "\u0126ad",
      "Tne",
      "Tli",
      "Erb",
      "\u0126am",
      "\u0120im",
      "Sib"
    ],
    "ordinal": {
      "one": "il{n}",
      "two": "il{n}",
      "few": "il{n}",
      "other": "il{n}"
    }
  };
  var mt_default = copy18;
  var copy19 = {
    month: [
      "januari",
      "februari",
      "maart",
      "april",
      "mei",
      "juni",
      "juli",
      "augustus",
      "september",
      "oktober",
      "november",
      "december"
    ],
    month_short: [
      "jan",
      "feb",
      "mrt",
      "apr",
      "mei",
      "jun",
      "jul",
      "aug",
      "sep",
      "okt",
      "nov",
      "dec"
    ],
    day: [
      "zondag",
      "maandag",
      "dinsdag",
      "woensdag",
      "donderdag",
      "vrijdag",
      "zaterdag"
    ],
    day_short: ["zo", "ma", "di", "wo", "do", "vr", "za"],
    ordinal: {
      one: "{n}ste",
      two: "{n}de",
      few: "{n}de",
      other: "{n}de"
    }
  };
  var nl_default = copy19;
  var copy20 = {
    "month": [
      "januar",
      "februar",
      "mars",
      "april",
      "mai",
      "juni",
      "juli",
      "august",
      "september",
      "oktober",
      "november",
      "desember"
    ],
    "month_short": [
      "jan",
      "feb",
      "mar",
      "apr",
      "mai",
      "jun",
      "jul",
      "aug",
      "sep",
      "okt",
      "nov",
      "des"
    ],
    "day": [
      "s\xF8ndag",
      "mandag",
      "tirsdag",
      "onsdag",
      "torsdag",
      "fredag",
      "l\xF8rdag"
    ],
    "day_short": [
      "s\xF8n",
      "man",
      "tir",
      "ons",
      "tor",
      "fre",
      "l\xF8r"
    ],
    "ordinal": {
      "one": "{n}ste",
      "two": "{n}de",
      "few": "{n}de",
      "other": "{n}de"
    }
  };
  var no_default = copy20;
  var copy21 = {
    "month": [
      "\u0698\u0627\u0646\u0648\u06CC\u0647",
      "\u0641\u0648\u0631\u06CC\u0647",
      "\u0645\u0627\u0631\u0633",
      "\u0622\u0648\u0631\u06CC\u0644",
      "\u0645\u0647",
      "\u0698\u0648\u0626\u0646",
      "\u0698\u0648\u0626\u06CC\u0647",
      "\u0627\u0648\u062A",
      "\u0633\u067E\u062A\u0627\u0645\u0628\u0631",
      "\u0627\u06A9\u062A\u0628\u0631",
      "\u0646\u0648\u0627\u0645\u0628\u0631",
      "\u062F\u0633\u0627\u0645\u0628\u0631"
    ],
    "month_short": [
      "\u0698\u0627\u0646",
      "\u0641\u0648\u0631",
      "\u0645\u0627\u0631",
      "\u0622\u0648\u0631",
      "\u0645\u0647",
      "\u0698\u0648\u0646",
      "\u0698\u0648\u06CC",
      "\u0627\u0648\u062A",
      "\u0633\u067E\u062A",
      "\u0627\u06A9\u062A",
      "\u0646\u0648\u0627",
      "\u062F\u0633\u0627"
    ],
    "day": [
      "\u06CC\u06A9\u0634\u0646\u0628\u0647",
      "\u062F\u0648\u0634\u0646\u0628\u0647",
      "\u0633\u0647\u200C\u0634\u0646\u0628\u0647",
      "\u0686\u0647\u0627\u0631\u0634\u0646\u0628\u0647",
      "\u067E\u0646\u062C\u0634\u0646\u0628\u0647",
      "\u062C\u0645\u0639\u0647",
      "\u0634\u0646\u0628\u0647"
    ],
    "day_short": [
      "\u06CC\u06A9",
      "\u062F\u0648",
      "\u0633\u0647",
      "\u0686\u0647\u0627\u0631",
      "\u067E\u0646\u062C",
      "\u062C\u0645\u0639\u0647",
      "\u0634\u0646\u0628\u0647"
    ],
    "ordinal": {
      "one": "{n}\u0645",
      "two": "{n}\u0645",
      "few": "{n}\u0645",
      "other": "{n}\u0645"
    }
  };
  var pe_default = copy21;
  var copy22 = {
    "month": [
      "stycze\u0144",
      "luty",
      "marzec",
      "kwiecie\u0144",
      "maj",
      "czerwiec",
      "lipiec",
      "sierpie\u0144",
      "wrzesie\u0144",
      "pa\u017Adziernik",
      "listopad",
      "grudzie\u0144"
    ],
    "month_short": [
      "sty",
      "lut",
      "mar",
      "kwi",
      "maj",
      "cze",
      "lip",
      "sie",
      "wrz",
      "pa\u017A",
      "lis",
      "gru"
    ],
    "day": [
      "niedziela",
      "poniedzia\u0142ek",
      "wtorek",
      "\u015Broda",
      "czwartek",
      "pi\u0105tek",
      "sobota"
    ],
    "day_short": [
      "niedz",
      "pon",
      "wt",
      "\u015Br",
      "czw",
      "pt",
      "sob"
    ],
    "ordinal": {
      "one": "{n}szy",
      "two": "{n}gi",
      "few": "{n}gi",
      "other": "{n}gi"
    }
  };
  var pl_default = copy22;
  var copy23 = {
    "month": [
      "janeiro",
      "fevereiro",
      "mar\xE7o",
      "abril",
      "maio",
      "junho",
      "julho",
      "agosto",
      "setembro",
      "outubro",
      "novembro",
      "dezembro"
    ],
    "month_short": [
      "jan",
      "fev",
      "mar",
      "abr",
      "mai",
      "jun",
      "jul",
      "ago",
      "set",
      "out",
      "nov",
      "dez"
    ],
    "day": [
      "domingo",
      "segunda-feira",
      "ter\xE7a-feira",
      "quarta-feira",
      "quinta-feira",
      "sexta-feira",
      "s\xE1bado"
    ],
    "day_short": [
      "dom",
      "seg",
      "ter",
      "qua",
      "qui",
      "sex",
      "s\xE1b"
    ],
    "ordinal": {
      "one": "{n}ro",
      "two": "{n}do",
      "few": "{n}ro",
      "other": "{n}to"
    }
  };
  var pt_default = copy23;
  var copy24 = {
    "month": [
      "ianuarie",
      "februarie",
      "martie",
      "aprilie",
      "mai",
      "iunie",
      "iulie",
      "august",
      "septembrie",
      "octombrie",
      "noiembrie",
      "decembrie"
    ],
    "month_short": [
      "ian",
      "feb",
      "mar",
      "apr",
      "mai",
      "iun",
      "iul",
      "aug",
      "sept",
      "oct",
      "nov",
      "dec"
    ],
    "day": [
      "duminic\u0103",
      "luni",
      "mar\u021Bi",
      "miercuri",
      "joi",
      "vineri",
      "s\xE2mb\u0103t\u0103"
    ],
    "day_short": [
      "dum",
      "lun",
      "mar",
      "mie",
      "joi",
      "vin",
      "s\xE2m"
    ],
    "ordinal": {
      "one": "{n}st",
      "two": "{n}nd",
      "few": "{n}rd",
      "other": "{n}th"
    }
  };
  var ro_default = copy24;
  var copy25 = {
    "month": [
      "\u042F\u043D\u0432\u0430\u0440\u044C",
      "\u0424\u0435\u0432\u0440\u0430\u043B\u044C",
      "\u041C\u0430\u0440\u0442",
      "\u0410\u043F\u0440\u0435\u043B\u044C",
      "\u041C\u0430\u0439",
      "\u0418\u044E\u043D\u044C",
      "\u0418\u044E\u043B\u044C",
      "\u0410\u0432\u0433\u0443\u0441\u0442",
      "\u0421\u0435\u043D\u0442\u044F\u0431\u0440\u044C",
      "\u041E\u043A\u0442\u044F\u0431\u0440\u044C",
      "\u041D\u043E\u044F\u0431\u0440\u044C",
      "\u0414\u0435\u043A\u0430\u0431\u0440\u044C"
    ],
    "month_short": [
      "\u044F\u043D\u0432",
      "\u0444\u0435\u0432",
      "\u043C\u0430\u0440",
      "\u0430\u043F\u0440",
      "\u043C\u0430\u0439",
      "\u0438\u044E\u043D",
      "\u0438\u044E\u043B",
      "\u0430\u0432\u0433",
      "\u0441\u0435\u043D",
      "\u043E\u043A\u0442",
      "\u043D\u043E\u044F",
      "\u0434\u0435\u043A"
    ],
    "day": [
      "\u0412\u043E\u0441\u043A\u0440\u0435\u0441\u0435\u043D\u044C\u0435",
      "\u041F\u043E\u043D\u0435\u0434\u0435\u043B\u044C\u043D\u0438\u043A",
      "\u0412\u0442\u043E\u0440\u043D\u0438\u043A",
      "\u0421\u0440\u0435\u0434\u0430",
      "\u0427\u0435\u0442\u0432\u0435\u0440\u0433",
      "\u041F\u044F\u0442\u043D\u0438\u0446\u0430",
      "\u0421\u0443\u0431\u0431\u043E\u0442\u0430"
    ],
    "day_short": [
      "\u0432\u0441",
      "\u043F\u043D",
      "\u0432\u0442",
      "\u0441\u0440",
      "\u0447\u0442",
      "\u043F\u0442",
      "\u0441\u0431"
    ],
    "ordinal": {
      "one": "{n}\u044B\u0439",
      "two": "{n}\u043E\u0439",
      "few": "{n}\u043E\u0439",
      "other": "{n}\u044B\u0439"
    }
  };
  var ru_default = copy25;
  var copy26 = {
    "month": [
      "januari",
      "februari",
      "mars",
      "april",
      "maj",
      "juni",
      "juli",
      "augusti",
      "september",
      "oktober",
      "november",
      "december"
    ],
    "month_short": [
      "jan",
      "feb",
      "mar",
      "apr",
      "maj",
      "jun",
      "jul",
      "aug",
      "sep",
      "okt",
      "nov",
      "dec"
    ],
    "day": [
      "s\xF6ndag",
      "m\xE5ndag",
      "tisdag",
      "onsdag",
      "torsdag",
      "fredag",
      "l\xF6rdag"
    ],
    "day_short": [
      "s\xF6n",
      "m\xE5n",
      "tis",
      "ons",
      "tors",
      "fre",
      "l\xF6r"
    ],
    "ordinal": {
      "one": "{n}ste",
      "two": "{n}de",
      "few": "{n}de",
      "other": "{n}de"
    }
  };
  var sv_default = copy26;
  var copy27 = {
    [Language.AM]: am_default,
    [Language.AR]: ar_default,
    [Language.BG]: bg_default,
    [Language.CY]: cy_default,
    [Language.DE]: de_default,
    [Language.DK]: dk_default,
    [Language.EN]: en_default,
    [Language.ES]: es_default,
    [Language.ET]: et_default,
    [Language.FI]: fi_default,
    [Language.FR]: fr_default,
    [Language.GR]: gr_default,
    [Language.HU]: hu_default,
    [Language.IR]: ir_default,
    [Language.IT]: it_default,
    [Language.LA]: la_default,
    [Language.LT]: lt_default,
    [Language.MT]: mt_default,
    [Language.NL]: nl_default,
    [Language.NO]: no_default,
    [Language.PE]: pe_default,
    [Language.PL]: pl_default,
    [Language.PT]: pt_default,
    [Language.RO]: ro_default,
    [Language.RU]: ru_default,
    [Language.SV]: sv_default
  };
  var getCopy = (value, options) => {
    const opts = __spreadValues(__spreadValues({}, defaultOptions), options);
    const langData = flattenObject(copy27[opts.language]);
    if (!isNaN(opts.index) && opts.index > -1) {
      const key = `${value}.${opts.index}`;
      return langData[key];
    }
    return copy27[opts.language][value];
  };
  var formatOrdinal = (day, options = {}) => {
    const opts = __spreadValues(__spreadValues({}, defaultOptions), options);
    const pr = new Intl.PluralRules(opts.language, { type: "ordinal" });
    const suffixes = copy27[opts.language].ordinal;
    if (!suffixes) {
      throw new Error(`Unsupported language: ${opts.language}`);
    }
    const suffix = suffixes[pr.select(day)];
    return suffix.replace("{n}", `${day}`);
  };
  var getDateObject = (value, options = {}) => {
    const opts = __spreadValues(__spreadValues({}, defaultOptions), options);
    return {
      day: opts.padded ? pad(value.getDate()) : value.getDate(),
      day_nth: formatOrdinal(value.getDate(), options),
      weekday: opts.padded ? pad(value.getDay()) : value.getDay(),
      weekday_name: getCopy("day", __spreadProps(__spreadValues({}, opts), { index: value.getDay() })),
      weekday_abbr: getCopy("day_short", __spreadProps(__spreadValues({}, opts), {
        index: value.getDay()
      })),
      month: opts.padded ? pad(value.getMonth() + 1) : value.getMonth() + 1,
      month_index: opts.padded ? pad(value.getMonth()) : value.getMonth(),
      month_name: getCopy("month", __spreadProps(__spreadValues({}, opts), { index: value.getMonth() })),
      month_abbr: getCopy("month_short", __spreadProps(__spreadValues({}, opts), {
        index: value.getMonth()
      })),
      year: opts.padded ? `${value.getFullYear()}` : value.getFullYear(),
      hours: opts.padded ? pad(value.getHours()) : value.getHours(),
      minutes: opts.padded ? pad(value.getMinutes()) : value.getMinutes(),
      seconds: opts.padded ? pad(value.getSeconds()) : value.getSeconds()
    };
  };
  var toDateFormat = (value) => {
    if (value instanceof Date)
      return value;
    else {
      const yrs = value.year || 1970;
      const mon = value.month || 1;
      const day = value.day || 1;
      const hrs = value.hrs || 0;
      const min = value.min || 0;
      const sec = value.sec || 0;
      return /* @__PURE__ */ new Date(`${yrs} ${mon} ${day} ${hrs}:${min}:${sec}`);
    }
  };
  var format = (date, options = {}) => {
    const d = toDateFormat(date);
    const opts = __spreadValues(__spreadValues({}, defaultOptions), options);
    const obj_padded = getDateObject(d, __spreadProps(__spreadValues({}, opts), { padded: true }));
    const obj = getDateObject(d, __spreadProps(__spreadValues({}, opts), { padded: true }));
    const replacers = __spreadValues({
      DD: obj_padded.day,
      DT: obj_padded.day_nth,
      Day: obj.weekday_name,
      Da: obj.weekday_abbr,
      D: obj.day,
      MM: obj_padded.month,
      Month: obj.month_name,
      Mo: obj.month_abbr,
      M: obj.month,
      mm: obj_padded.minutes,
      m: obj.minutes,
      ss: obj_padded.seconds,
      s: obj.seconds,
      hh: obj_padded.hours,
      h: obj.hours,
      YY: obj.year,
      Y: obj_padded.year.substring(2, 4)
    }, opts.replace);
    let template = opts.template;
    Object.entries(replacers).forEach(([key, value]) => {
      if (template.indexOf(key) < 0)
        return;
      const regex = new RegExp(key, "g");
      template = template.replace(regex, `${value}`);
    });
    return template;
  };

  // ../nizel/dist/utils.js
  var escapeHtml = (value) => {
    const text = String(value);
    return /[&<>"]/.test(text) ? text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;") : text;
  };
  var slugify = (value, style = "github") => {
    if (style === "classic") {
      return value.toLowerCase().replace(/[^\w\s-]/g, "").replace(/[\s_]+/g, "-").replace(/^-+|-+$/g, "");
    }
    return P(value);
  };
  var textFromUnknown = (value) => {
    if (value === null || value === void 0)
      return "";
    if (value instanceof Date)
      return value.toISOString();
    return String(value);
  };
  var getPath = (source, path) => {
    return path.split(".").reduce((value, part) => {
      if (value && typeof value === "object" && part in value) {
        return value[part];
      }
      return void 0;
    }, source);
  };
  var uniqueSlug = (base, seen) => {
    const fallback2 = base || "section";
    const count = seen.get(fallback2) ?? 0;
    seen.set(fallback2, count + 1);
    return count === 0 ? fallback2 : `${fallback2}-${count + 1}`;
  };

  // ../nizel/dist/defaults.js
  var lowerFilter = (value) => textFromUnknown(value).toLowerCase();
  var upperFilter = (value) => textFromUnknown(value).toUpperCase();
  var titleFilter = (value) => I(textFromUnknown(value)).replace(/\w\S*/g, (word) => {
    return word.charAt(0).toUpperCase() + word.slice(1).toLowerCase();
  });
  var kebabFilter = L;
  var camelFilter = j;
  var pascalFilter = $;
  var snakeFilter = m;
  var constantFilter = b;
  var capitalFilter = (value) => {
    const text = textFromUnknown(value);
    return text.charAt(0).toUpperCase() + text.slice(1);
  };
  var dotFilter = (value) => textFromUnknown(value).toLowerCase().replace(/[\s_-]+/g, ".").replace(/^\.+|\.+$/g, "");
  var headerFilter = (value) => textFromUnknown(value).replace(/\w+/g, (word) => word.charAt(0).toUpperCase() + word.slice(1).toLowerCase()).replace(/[\s_-]+/g, "-").replace(/^-+|-+$/g, "");
  var pathFilter = (value) => textFromUnknown(value).toLowerCase().replace(/[\s_-]+/g, "/").replace(/^\/+|\/+$/g, "");
  var sentenceFilter = (value) => I(textFromUnknown(value));
  var formatFilter = (value, kind, localeOrCurrency = "en-US") => {
    if (kind === "currency") {
      return new Intl.NumberFormat("en-US", {
        style: "currency",
        currency: textFromUnknown(localeOrCurrency)
      }).format(Number(value));
    }
    if (kind === "number") {
      const pattern = textFromUnknown(localeOrCurrency);
      return formatNumber(Number(value), pattern);
    }
    if (kind === "date") {
      const date = new Date(textFromUnknown(value));
      const template = textFromUnknown(localeOrCurrency);
      const dateObject = getDateObject(date);
      return format(date, {
        template: normalizeDateTemplate(template === "en-US" ? "YY-MM-DD" : template),
        replace: {
          "\xA7\xA7\xA7": String(dateObject.month_name)
        }
      });
    }
    return textFromUnknown(value);
  };
  var formatNumber = (value, pattern) => {
    const digits = (pattern.match(/0/g) || []).length;
    const [intPart, decPart] = pattern.split(".");
    const decimals = decPart ? decPart.length : 0;
    return new Intl.NumberFormat("en-US", {
      minimumFractionDigits: decimals,
      maximumFractionDigits: decimals
    }).format(value);
  };
  var normalizeDateTemplate = (template) => {
    return template.replaceAll("yyyy", "YY").replaceAll("MMM", "\xA7\xA7\xA7").replaceAll("dd", "DD");
  };
  var defaultFilters = {
    lower: lowerFilter,
    upper: upperFilter,
    title: titleFilter,
    capital: capitalFilter,
    capitalize: capitalFilter,
    kebab: kebabFilter,
    camel: camelFilter,
    pascal: pascalFilter,
    snake: snakeFilter,
    constant: constantFilter,
    dot: dotFilter,
    header: headerFilter,
    path: pathFilter,
    sentence: sentenceFilter,
    format: formatFilter
  };
  var defaultOptions2 = {
    output: "html",
    frontmatter: true,
    template: { missing: "keep", raw: false, filters: defaultFilters },
    toc: true,
    anchors: true,
    autolinks: { enabled: true },
    safe: true,
    unwrapStandaloneImages: false,
    elements: {},
    blocks: {},
    data: {},
    plugins: [],
    transforms: []
  };

  // ../nizel/dist/options.js
  function resolveOptions(baseOptions = {}, runtimeOptions = {}) {
    const plugins = [
      ...baseOptions.plugins ?? [],
      ...runtimeOptions.plugins ?? []
    ];
    const pluginOptions = plugins.reduce((merged, plugin) => {
      const pluginTemplate = plugin.template ?? (plugin.filters ? { filters: plugin.filters } : void 0);
      return mergeOptions(merged, {
        ...plugin.options,
        elements: plugin.elements,
        blocks: plugin.blocks,
        transforms: plugin.transforms,
        template: pluginTemplate
      });
    }, {});
    return mergeOptions(mergeOptions(mergeOptions(defaultOptions2, pluginOptions), baseOptions), runtimeOptions);
  }
  function mergeOptions(left, right) {
    if (!right)
      return left;
    return {
      ...left,
      ...right,
      data: {
        ...left.data ?? {},
        ...right.data ?? {}
      },
      variables: {
        ...left.variables ?? {},
        ...right.variables ?? {}
      },
      meta: {
        ...left.meta ?? {},
        ...right.meta ?? {}
      },
      elements: {
        ...left.elements ?? {},
        ...right.elements ?? {}
      },
      blocks: {
        ...left.blocks ?? {},
        ...right.blocks ?? {}
      },
      transforms: [...left.transforms ?? [], ...right.transforms ?? []],
      template: mergeTemplateOptions(left.template, right.template)
    };
  }
  function mergeTemplateOptions(left, right) {
    if (right === false)
      return false;
    if (left === false && right === void 0)
      return false;
    if (left === false && right === true)
      return {};
    if (left === false)
      left = {};
    if (right === true || right === void 0)
      right = {};
    if (left === true || left === void 0)
      left = {};
    return {
      ...left,
      ...right,
      filters: {
        ...defaultFilters,
        ...left.filters,
        ...right.filters
      }
    };
  }

  // ../nizel/dist/parse/block.js
  var isRawHtmlBlockLine = (line) => {
    return /^<\/?[A-Za-z][A-Za-z0-9-]*(?=[\s>/])[\s\S]*>$/.test(line.trim());
  };
  var isThematicBreak = (line) => {
    return /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/.test(line);
  };
  var isSetextUnderline = (line) => {
    return /^ {0,3}(=+|-+)\s*$/.exec(line);
  };
  var trimClosingHeadingHashes = (source) => {
    if (/^#+\s*$/.test(source))
      return "";
    return source.replace(/\s+#+\s*$/, "").trim();
  };
  var normalizeParagraphLine = (line) => {
    return line.replace(/^ {0,3}/, "").trimStart();
  };
  var normalizeParagraphSource = (lines) => {
    return lines.join("\n").replace(/[ \t]+$/, "");
  };

  // ../nizel/dist/parse/html.js
  var htmlBlockTags = /* @__PURE__ */ new Set([
    "address",
    "article",
    "aside",
    "base",
    "basefont",
    "blockquote",
    "body",
    "caption",
    "center",
    "col",
    "colgroup",
    "dd",
    "details",
    "dialog",
    "dir",
    "div",
    "dl",
    "dt",
    "fieldset",
    "figcaption",
    "figure",
    "footer",
    "form",
    "frame",
    "frameset",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "head",
    "header",
    "hr",
    "html",
    "iframe",
    "legend",
    "li",
    "link",
    "main",
    "menu",
    "menuitem",
    "nav",
    "noframes",
    "ol",
    "optgroup",
    "option",
    "p",
    "param",
    "search",
    "section",
    "summary",
    "table",
    "tbody",
    "td",
    "tfoot",
    "th",
    "thead",
    "title",
    "tr",
    "track",
    "ul"
  ]);
  var readHtmlBlock = (lines, startIndex) => {
    const line = lines[startIndex];
    if (!/^ {0,3}</.test(line))
      return null;
    const trimmed = line.trimStart();
    const closedBy = htmlBlockClosingPattern(trimmed);
    if (closedBy) {
      return readHtmlBlockUntil(lines, startIndex, closedBy);
    }
    if (isBlankTerminatedHtmlBlockStart(trimmed)) {
      return readHtmlBlockUntilBlank(lines, startIndex);
    }
    return null;
  };
  var isInterruptingHtmlBlockStart = (line) => {
    if (!/^ {0,3}</.test(line))
      return false;
    const trimmed = line.trimStart();
    return htmlBlockClosingPattern(trimmed) !== null || isBlockTagHtmlBlockStart(trimmed);
  };
  var isValidInlineHtmlToken = (source) => {
    if (/^(?:<!-->|<!--->|<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<![A-Z][^>]*>|<!\[CDATA\[[\s\S]*?\]\]>)$/u.test(source)) {
      return true;
    }
    if (isValidInlineHtmlTag(source))
      return true;
    return /\n/.test(source) && /^<[A-Za-z][A-Za-z0-9-]*(?:\s|>)/.test(source) && !/[A-Za-z0-9_.:-]![A-Za-z0-9_.:-]/.test(source);
  };
  var htmlBlockClosingPattern = (trimmed) => {
    if (/^<(script|pre|style|textarea)(?:\s|>|$)/i.test(trimmed)) {
      return new RegExp(`</${/^<([A-Za-z][A-Za-z0-9-]*)/.exec(trimmed)?.[1]}>`, "i");
    }
    if (/^<!--/.test(trimmed))
      return /-->/;
    if (/^<\?/.test(trimmed))
      return /\?>/;
    if (/^<![A-Z]/.test(trimmed))
      return />/;
    if (/^<!\[CDATA\[/.test(trimmed))
      return /\]\]>/;
    return null;
  };
  var readHtmlBlockUntil = (lines, startIndex, close) => {
    const html = [];
    let index = startIndex;
    while (index < lines.length) {
      html.push(lines[index]);
      if (close.test(lines[index]))
        break;
      index += 1;
    }
    return { value: html.join("\n"), endIndex: index };
  };
  var isBlankTerminatedHtmlBlockStart = (trimmed) => {
    if (isBlockTagHtmlBlockStart(trimmed))
      return true;
    return isValidInlineHtmlTag(trimmed);
  };
  var isValidInlineHtmlTag = (source) => {
    return /^<[A-Za-z][A-Za-z0-9-]*(?:\s+[A-Za-z_:][A-Za-z0-9_.:-]*(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*\s*\/?>\s*$/.test(source) || /^<\/[A-Za-z][A-Za-z0-9-]*\s*>\s*$/.test(source);
  };
  var isBlockTagHtmlBlockStart = (trimmed) => {
    if (!/^<\/?([A-Za-z][A-Za-z0-9-]*)(?:\s|\/?>|$)/.test(trimmed))
      return false;
    const tag = /^<\/?([A-Za-z][A-Za-z0-9-]*)/.exec(trimmed)?.[1].toLowerCase();
    return tag !== void 0 && htmlBlockTags.has(tag);
  };
  var readHtmlBlockUntilBlank = (lines, startIndex) => {
    const html = [];
    let index = startIndex;
    while (index < lines.length && lines[index].trim()) {
      html.push(lines[index]);
      index += 1;
    }
    return { value: html.join("\n"), endIndex: index - 1 };
  };

  // ../nizel/dist/parse/list.js
  var parseListMarker = (line) => {
    const expanded = line.includes("	") ? expandListMarkerTabs(line) : line;
    const unordered = /^( {0,3})([-*+])([ \t]*)(.*)$/.exec(expanded);
    if (unordered && (unordered[3].length > 0 || unordered[4] === "")) {
      return {
        body: listMarkerBody(unordered[3], unordered[4]),
        contentIndent: listContentIndent(unordered[1].length, unordered[2].length, unordered[3].length),
        marker: unordered[2],
        ordered: false
      };
    }
    const ordered = /^( {0,3})(\d{1,9})([.)])([ \t]*)(.*)$/.exec(expanded);
    if (ordered && (ordered[4].length > 0 || ordered[5] === "")) {
      return {
        body: listMarkerBody(ordered[4], ordered[5]),
        contentIndent: listContentIndent(ordered[1].length, ordered[2].length + 1, ordered[4].length),
        marker: ordered[3],
        ordered: true,
        start: Number(ordered[2])
      };
    }
    return null;
  };
  var listMarkerBody = (padding, body) => {
    return padding.length > 4 ? `${padding.slice(1)}${body}` : body;
  };
  var expandListMarkerTabs = (line) => {
    let result = "";
    let cursor = 0;
    let inMarkerPadding = false;
    while (cursor < line.length) {
      const character = line[cursor];
      if (character === "	" && (inMarkerPadding || /^ {0,3}(?:[-*+]|\d{1,9}[.)])$/.test(result))) {
        const column = result.length;
        result += " ".repeat(4 - column % 4);
        inMarkerPadding = true;
        cursor += 1;
        continue;
      }
      result += character;
      if (/^ {0,3}(?:[-*+]|\d{1,9}[.)])$/.test(result)) {
        inMarkerPadding = true;
      } else if (inMarkerPadding && character !== " ") {
        inMarkerPadding = false;
      }
      cursor += 1;
    }
    return result;
  };
  var isSameListMarker = (opening, current) => {
    return opening.ordered ? current.marker === opening.marker : current.marker === opening.marker;
  };
  var isParagraphInterruptingListMarker = (line) => {
    const marker = parseListMarker(line);
    return marker !== null && marker.body !== "" && (!marker.ordered || marker.start === 1);
  };
  var listContentIndent = (indent, markerLength, padding) => {
    return indent + markerLength + (padding > 0 && padding <= 4 ? padding : 1);
  };

  // ../nizel/dist/parse/table.js
  var isTableStart = (lines, index) => {
    return Boolean(lines[index]?.includes("|") && lines[index + 1] && /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(lines[index + 1]));
  };
  var readTable = (lines, startIndex, options, parseInline2) => {
    const headers = splitTableRow(lines[startIndex]);
    const align = splitTableRow(lines[startIndex + 1]).map((cell) => {
      const trimmed = cell.trim();
      if (trimmed.startsWith(":") && trimmed.endsWith(":"))
        return "center";
      if (trimmed.endsWith(":"))
        return "right";
      if (trimmed.startsWith(":"))
        return "left";
      return null;
    });
    const rows = [
      {
        type: "tableRow",
        children: headers.map((cell) => ({
          type: "tableCell",
          children: parseInline2(cell.trim(), options)
        }))
      }
    ];
    let index = startIndex + 2;
    while (index < lines.length && lines[index].includes("|") && lines[index].trim()) {
      rows.push({
        type: "tableRow",
        children: splitTableRow(lines[index]).map((cell) => ({
          type: "tableCell",
          children: parseInline2(cell.trim(), options)
        }))
      });
      index += 1;
    }
    return { table: { type: "table", align, children: rows }, endIndex: index - 1 };
  };
  var splitTableRow = (line) => {
    return line.trim().replace(/^\||\|$/g, "").split("|");
  };

  // ../nizel/dist/parse/blockquote.js
  var canContinueBlockquoteLazily = (line, options, lines, index) => {
    return Boolean(line.trim() && !/^ {0,3}> ?/.test(line) && !/^ {0,3}(`{3,}|~{3,})/.test(line) && !isThematicBreak(line) && !parseListMarker(line) && !isTableStart(lines, index) && !(options.safe === false && isInterruptingHtmlBlockStart(line)));
  };
  var canStartLazyBlockquoteContinuation = (line, options, lines, index, isBlockStart2) => {
    const candidate = lazyContinuationCandidate(line);
    return Boolean(candidate.trim() && !/^ {0,3}(`{3,}|~{3,})/.test(candidate) && !/^ {4}/.test(candidate) && !isBlockStart2(candidate, options, lines, index));
  };
  var lazyContinuationCandidate = (line) => {
    let candidate = line;
    while (true) {
      const quoteMarker = /^ {0,3}> ?(.*)$/.exec(candidate);
      if (quoteMarker) {
        candidate = quoteMarker[1];
        continue;
      }
      const marker = parseListMarker(candidate);
      if (marker && /^ {0,3}> ?/.test(marker.body)) {
        candidate = marker.body;
        continue;
      }
      return candidate;
    }
  };

  // ../nizel/dist/parse/common.js
  var normalizeReference = (label) => {
    return label.trim().replace(/\s+/g, " ").replace(/[ẞß]/g, "ss").toLowerCase();
  };
  var normalizeReferenceLabelForLookup = (label) => {
    return normalizeReference(label.replace(/\\([\[\]])/g, "$1"));
  };
  var normalizeHref = (destination) => {
    try {
      return encodeURI(destination).replace(/%25([0-9A-Fa-f]{2})/g, "%$1");
    } catch {
      return destination;
    }
  };
  var decodeStringContent = (source) => {
    return source.replace(/\\([!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~])/g, "$1").replace(/&([A-Za-z][A-Za-z0-9]+|#[0-9]+|#[xX][0-9A-Fa-f]+);/g, (_, entity) => decodeEntity(entity));
  };
  var decodeEntity = (entity) => {
    if (/^#[xX]/.test(entity))
      return decodeCodePoint(entity, Number.parseInt(entity.slice(2), 16));
    if (entity.startsWith("#"))
      return decodeCodePoint(entity, Number.parseInt(entity.slice(1), 10));
    const named = {
      amp: "&",
      lt: "<",
      gt: ">",
      quot: '"',
      apos: "'",
      nbsp: "\xA0",
      AElig: "\xC6",
      auml: "\xE4",
      ClockwiseContourIntegral: "\u2232",
      copy: "\xA9",
      Dcaron: "\u010E",
      DifferentialD: "\u2146",
      frac34: "\xBE",
      HilbertSpace: "\u210B",
      ngE: "\u2267\u0338",
      ouml: "\xF6"
    };
    return named[entity] ?? `&${entity};`;
  };
  var decodeCodePoint = (entity, codePoint) => {
    if (!Number.isFinite(codePoint) || codePoint === 0 || codePoint >= 55296 && codePoint <= 57343) {
      return "\uFFFD";
    }
    if (codePoint < 0 || codePoint > 1114111) {
      return `&${entity};`;
    }
    return String.fromCodePoint(codePoint);
  };

  // ../nizel/dist/parse/code.js
  var openingFenceClosePattern = (line) => {
    const fence = /^( {0,3})(`{3,}|~{3,})[ \t]*(.*)$/.exec(line);
    if (!fence)
      return null;
    const marker = fence[2][0];
    return new RegExp(`^ {0,3}\\${marker}{${fence[2].length},}\\s*$`);
  };
  var normalizeCodeSpan = (code) => {
    const normalized = code.replace(/\r?\n/g, " ");
    return normalized.startsWith(" ") && normalized.endsWith(" ") && /[^ ]/.test(normalized) ? normalized.slice(1, -1) : normalized;
  };
  var parseFenceInfo = (info, marker) => {
    const meta = decodeStringContent(info.trim());
    if (marker === "`" && meta.includes("`"))
      return { meta: "", valid: false };
    if (!meta)
      return { meta: "", valid: true };
    const [lang] = meta.split(/\s+/, 1);
    return { lang, meta, valid: true };
  };
  var stripFenceIndent = (line, indent) => {
    let removed = 0;
    while (removed < indent && line.startsWith(" ")) {
      line = line.slice(1);
      removed += 1;
    }
    return line;
  };
  var parseCodeMeta = (meta) => {
    const filename = /filename=(?:"([^"]+)"|'([^']+)'|(\S+))/.exec(meta);
    const highlight = /\{([^}]+)\}/.exec(meta);
    return {
      filename: filename?.[1] ?? filename?.[2] ?? filename?.[3],
      highlightLines: highlight ? expandLineRanges(highlight[1]) : void 0
    };
  };
  var expandLineRanges = (source) => {
    const lines = /* @__PURE__ */ new Set();
    for (const part of source.split(",")) {
      const [start, end] = part.trim().split("-").map(Number);
      if (!Number.isFinite(start))
        continue;
      if (Number.isFinite(end)) {
        for (let line = start; line <= end; line += 1)
          lines.add(line);
      } else {
        lines.add(start);
      }
    }
    return [...lines].sort((a, b2) => a - b2);
  };

  // ../nizel/dist/parse/custom.js
  var readCustomBlock = (lines, startIndex) => {
    const firstDelimiter = findDelimiter(lines, startIndex + 1);
    if (firstDelimiter === -1) {
      return {
        props: {},
        content: lines.slice(startIndex + 1).join("\n"),
        endIndex: lines.length - 1
      };
    }
    const beforeDelimiter = lines.slice(startIndex + 1, firstDelimiter);
    if (beforeDelimiter.length > 0 && beforeDelimiter.every(isPropOrBlank)) {
      const closingDelimiter = findDelimiter(lines, firstDelimiter + 1);
      return {
        props: parseProps(beforeDelimiter),
        content: lines.slice(firstDelimiter + 1, closingDelimiter === -1 ? lines.length : closingDelimiter).join("\n"),
        endIndex: closingDelimiter === -1 ? lines.length - 1 : closingDelimiter
      };
    }
    return {
      props: {},
      content: beforeDelimiter.join("\n"),
      endIndex: firstDelimiter
    };
  };
  var findDelimiter = (lines, startIndex) => {
    for (let index = startIndex; index < lines.length; index += 1) {
      if (lines[index].trim() === "::")
        return index;
    }
    return -1;
  };
  var isPropOrBlank = (line) => {
    return !line.trim() || /^[A-Za-z0-9_-]+:\s*.*$/.test(line.trim());
  };
  var parseProps = (lines) => {
    const props = {};
    for (const line of lines) {
      const match = /^([A-Za-z0-9_-]+):\s*(.*)$/.exec(line.trim());
      if (!match)
        continue;
      props[match[1]] = parsePrimitive(match[2]);
    }
    return props;
  };
  var parsePrimitive = (value) => {
    const trimmed = value.trim();
    if (trimmed === "true")
      return true;
    if (trimmed === "false")
      return false;
    if (trimmed === "null")
      return null;
    if (/^-?\d+(\.\d+)?$/.test(trimmed))
      return Number(trimmed);
    return trimmed.replace(/^["']|["']$/g, "");
  };
  var splitWords = (source) => {
    return source.trim() ? source.trim().split(/\s+/) : [];
  };

  // ../nizel/dist/parse/autolink.js
  var trimTrailingPunctuation = (source) => {
    return source.replace(/[),.;:!?]+$/g, "");
  };
  var getAutolinkOptions = (options) => {
    return typeof options === "object" ? options : { enabled: options !== false };
  };
  var isExternalHref = (href) => {
    return /^(?:https?:)?\/\//.test(href);
  };

  // ../nizel/dist/parse/emphasis.js
  var resolveRemainingEmphasis = (nodes) => {
    const tokens = tokenizeEmphasisDelimiters(nodes);
    let changed = true;
    while (changed) {
      changed = false;
      for (let closeIndex = 0; closeIndex < tokens.length; closeIndex += 1) {
        const closer = tokens[closeIndex];
        if (closer.type !== "delimiter" || !closer.close || closer.length === 0)
          continue;
        for (let openIndex = closeIndex - 1; openIndex >= 0; openIndex -= 1) {
          const opener = tokens[openIndex];
          if (opener.type !== "delimiter" || !opener.open || opener.char !== closer.char || opener.length === 0) {
            continue;
          }
          if (isForbiddenDelimiterMatch(opener, closer))
            continue;
          const size = opener.length >= 2 && closer.length >= 2 ? 2 : 1;
          const children = inlineTokensToNodes(tokens.slice(openIndex + 1, closeIndex));
          const wrapped = size === 2 ? { type: "strong", children: resolveRemainingEmphasis(children) } : { type: "emphasis", children: resolveRemainingEmphasis(children) };
          const replacement = [];
          if (opener.length > size) {
            replacement.push({ ...opener, length: opener.length - size });
          }
          replacement.push({ type: "node", node: wrapped });
          if (closer.length > size) {
            replacement.push({ ...closer, length: closer.length - size });
          }
          tokens.splice(openIndex, closeIndex - openIndex + 1, ...replacement);
          changed = true;
          closeIndex = -1;
          break;
        }
      }
    }
    return inlineTokensToNodes(tokens);
  };
  var tokenizeEmphasisDelimiters = (nodes) => {
    const tokens = [];
    for (let nodeIndex = 0; nodeIndex < nodes.length; nodeIndex += 1) {
      const node = nodes[nodeIndex];
      if (node.type !== "text") {
        tokens.push({ type: "node", node });
        continue;
      }
      if (node.escaped === true) {
        tokens.push({ type: "node", node });
        continue;
      }
      let cursor = 0;
      while (cursor < node.value.length) {
        const character = node.value[cursor];
        if (character !== "*" && character !== "_") {
          const nextDelimiter = nextEmphasisDelimiter(node.value, cursor + 1);
          tokens.push({
            type: "node",
            node: { type: "text", value: node.value.slice(cursor, nextDelimiter) }
          });
          cursor = nextDelimiter;
          continue;
        }
        const runStart = cursor;
        while (cursor < node.value.length && node.value[cursor] === character)
          cursor += 1;
        const runLength = cursor - runStart;
        const before = previousCharacter(tokens);
        const after = node.value[cursor] ?? nextInlineCharacter(nodes, nodeIndex + 1);
        const { open, close } = classifyDelimiterRun(character, before, after);
        tokens.push({
          type: "delimiter",
          char: character,
          close,
          length: runLength,
          open
        });
      }
    }
    return tokens;
  };
  var nextInlineCharacter = (nodes, startIndex) => {
    for (let index = startIndex; index < nodes.length; index += 1) {
      const character = firstInlineCharacter(nodes[index]);
      if (character)
        return character;
    }
    return "";
  };
  var firstInlineCharacter = (node) => {
    if (node.type === "text" && node.value)
      return node.value[0];
    if (node.type === "lineBreak")
      return "\n";
    if (node.type === "inlineCode" && node.code)
      return node.code[0];
    if (node.type === "image" && node.alt)
      return node.alt[0];
    if ("children" in node && node.children.length > 0) {
      for (const child of node.children) {
        const character = firstInlineCharacter(child);
        if (character)
          return character;
      }
    }
    return "";
  };
  var isForbiddenDelimiterMatch = (opener, closer) => {
    if (opener.char !== closer.char)
      return true;
    if (!(opener.close || closer.open))
      return false;
    return (opener.length + closer.length) % 3 === 0 && opener.length % 3 !== 0 && closer.length % 3 !== 0;
  };
  var nextEmphasisDelimiter = (source, startIndex) => {
    let index = startIndex;
    while (index < source.length && source[index] !== "*" && source[index] !== "_")
      index += 1;
    return index;
  };
  var previousCharacter = (tokens) => {
    for (let index = tokens.length - 1; index >= 0; index -= 1) {
      const token = tokens[index];
      if (token.type === "delimiter" && token.length > 0)
        return token.char;
      if (token.type === "node") {
        const character = lastInlineCharacter(token.node);
        if (character)
          return character;
      }
    }
    return "";
  };
  var lastInlineCharacter = (node) => {
    if (node.type === "text" && node.value)
      return node.value[node.value.length - 1];
    if (node.type === "lineBreak")
      return "\n";
    if (node.type === "inlineCode" && node.code)
      return node.code[node.code.length - 1];
    if (node.type === "image" && node.alt)
      return node.alt[node.alt.length - 1];
    if ("children" in node && node.children.length > 0) {
      for (let index = node.children.length - 1; index >= 0; index -= 1) {
        const character = lastInlineCharacter(node.children[index]);
        if (character)
          return character;
      }
    }
    return "";
  };
  var classifyDelimiterRun = (char, before, after) => {
    const beforeWhitespace = before === "" || /\s/u.test(before);
    const afterWhitespace = after === "" || /\s/u.test(after);
    const beforePunctuation = isUnicodePunctuation(before);
    const afterPunctuation = isUnicodePunctuation(after);
    const leftFlanking = !afterWhitespace && (!afterPunctuation || beforeWhitespace || beforePunctuation);
    const rightFlanking = !beforeWhitespace && (!beforePunctuation || afterWhitespace || afterPunctuation);
    if (char === "_") {
      return {
        open: leftFlanking && (!rightFlanking || beforePunctuation),
        close: rightFlanking && (!leftFlanking || afterPunctuation)
      };
    }
    return { open: leftFlanking, close: rightFlanking };
  };
  var isUnicodePunctuation = (character) => {
    return character !== "" && /[\p{P}\p{S}]/u.test(character);
  };
  var inlineTokensToNodes = (tokens) => {
    const nodes = [];
    for (const token of tokens) {
      if (token.type === "delimiter") {
        appendTextNode(nodes, token.char.repeat(token.length));
        continue;
      }
      if (token.node.type === "text") {
        appendTextNode(nodes, token.node.value);
      } else {
        nodes.push(token.node);
      }
    }
    return nodes;
  };
  var appendTextNode = (nodes, value) => {
    if (!value)
      return;
    const previous = nodes[nodes.length - 1];
    if (previous?.type === "text") {
      previous.value += value;
      return;
    }
    nodes.push({ type: "text", value });
  };

  // ../nizel/dist/parse/inline-links.js
  var nextInlineLabelOpener = (source, startIndex) => {
    for (let index = startIndex; index < source.length; index += 1) {
      if (source[index] === "\\") {
        index += 1;
        continue;
      }
      if (source[index] === "[")
        return index;
      if (source[index] === "!" && source[index + 1] === "[")
        return index;
    }
    return -1;
  };
  var findBalancedLabelEnd = (source, startIndex) => {
    let depth = 0;
    for (let index = startIndex; index < source.length; index += 1) {
      if (source[index] === "\\") {
        index += 1;
        continue;
      }
      if (source[index] === "`") {
        const ticks = /^`+/.exec(source.slice(index))?.[0] ?? "`";
        const close = source.indexOf(ticks, index + ticks.length);
        if (close !== -1) {
          index = close + ticks.length - 1;
          continue;
        }
      }
      if (source[index] === "<") {
        const close = source.indexOf(">", index + 1);
        if (close !== -1) {
          const token = source.slice(index, close + 1);
          if (isAutolinkToken(token) || isValidInlineHtmlToken(token)) {
            index = close;
            continue;
          }
        }
      }
      if (source[index] === "[") {
        depth += 1;
        continue;
      }
      if (source[index] === "]") {
        if (depth === 0)
          return index;
        depth -= 1;
      }
    }
    return -1;
  };
  var containsInlineLink = (label) => {
    return new RegExp("(?<!!)\\[[^\\]]+\\](?:\\(|\\[)").test(label);
  };
  var isAutolinkToken = (token) => {
    return /^<[A-Za-z][A-Za-z0-9+.-]{1,31}:[^<>\s]*>$/.test(token) || /^<[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?)*>$/i.test(token);
  };
  var readInlineReferenceDestination = (source, labelEnd, label, state) => {
    if (source[labelEnd + 1] !== "[")
      return null;
    const referenceEnd = findReferenceLabelEnd(source, labelEnd + 2);
    if (referenceEnd === -1)
      return null;
    const referenceLabel = source.slice(labelEnd + 2, referenceEnd);
    const reference = state.references.get(normalizeReferenceLabelForLookup(referenceLabel || label));
    if (!reference)
      return null;
    return {
      href: reference.href,
      title: reference.title,
      endIndex: referenceEnd
    };
  };
  var readUnresolvedInlineReferenceEnd = (source, labelEnd) => {
    if (source[labelEnd + 1] !== "[")
      return -1;
    return findReferenceLabelEnd(source, labelEnd + 2);
  };
  var canTailBecomeReferenceLink = (source, unresolvedReferenceEnd, referenceLabel, state) => {
    return readInlineReferenceDestination(source, unresolvedReferenceEnd, referenceLabel, state) !== null;
  };
  var findReferenceLabelEnd = (source, startIndex) => {
    for (let index = startIndex; index < source.length; index += 1) {
      if (source[index] === "\\") {
        index += 1;
        continue;
      }
      if (source[index] === "[")
        return -1;
      if (source[index] === "]")
        return index;
    }
    return -1;
  };
  var readInlineDestination = (source, openParenIndex) => {
    if (source[openParenIndex] !== "(")
      return null;
    let cursor = openParenIndex + 1;
    while (/[ \t\n]/.test(source[cursor] ?? ""))
      cursor += 1;
    let href = "";
    if (source[cursor] === "<") {
      const close = source.indexOf(">", cursor + 1);
      if (close === -1)
        return null;
      href = source.slice(cursor + 1, close);
      if (/[<>\\\n]/.test(href))
        return null;
      cursor = close + 1;
    } else {
      let depth = 0;
      while (cursor < source.length) {
        const character = source[cursor];
        if (character === "\\" && source[cursor + 1]) {
          if (/[!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~]/.test(source[cursor + 1])) {
            href += source[cursor + 1];
            cursor += 2;
          } else {
            href += character;
            cursor += 1;
          }
          continue;
        }
        if (character === "(") {
          depth += 1;
          href += character;
          cursor += 1;
          continue;
        }
        if (character === ")") {
          if (depth === 0)
            break;
          depth -= 1;
          href += character;
          cursor += 1;
          continue;
        }
        if (/[ \t\n]/.test(character) && depth === 0)
          break;
        href += character;
        cursor += 1;
      }
      if (depth !== 0)
        return null;
    }
    let title;
    const beforeTitle = cursor;
    while (/[ \t\n]/.test(source[cursor] ?? ""))
      cursor += 1;
    if (cursor > beforeTitle && ['"', "'", "("].includes(source[cursor])) {
      const opener = source[cursor];
      const closer = opener === "(" ? ")" : opener;
      cursor += 1;
      let value = "";
      while (cursor < source.length) {
        if (source[cursor] === "\\" && source[cursor + 1]) {
          value += source[cursor + 1];
          cursor += 2;
          continue;
        }
        if (source[cursor] === closer)
          break;
        value += source[cursor];
        cursor += 1;
      }
      if (source[cursor] !== closer)
        return null;
      title = value;
      cursor += 1;
      while (/[ \t\n]/.test(source[cursor] ?? ""))
        cursor += 1;
    }
    if (source[cursor] !== ")")
      return null;
    return { href, title, endIndex: cursor };
  };
  var normalizeInlineDestination = (destination) => {
    return destination.startsWith("<") && destination.endsWith(">") ? destination.slice(1, -1) : destination;
  };
  var inlineTitleFromGroups = (groups, prefix) => {
    const title = groups[prefix] ?? groups[`${prefix}Single`] ?? groups[`${prefix}Paren`];
    return title === void 0 ? void 0 : decodeStringContent(title);
  };

  // ../nizel/dist/parse/inline-text.js
  var stripInlineNodes = (nodes) => {
    return nodes.map((node) => {
      if (node.type === "text")
        return node.value;
      if (node.type === "lineBreak")
        return "\n";
      if (node.type === "inlineCode")
        return node.code;
      if (node.type === "image")
        return node.alt ?? "";
      if ("children" in node)
        return stripInlineNodes(node.children);
      return "";
    }).join("");
  };
  var trimTrailingSoftBreakSpace = (nodes) => {
    const previous = nodes[nodes.length - 1];
    if (previous?.type === "text" && new RegExp("(?<! ) $").test(previous.value)) {
      previous.value = previous.value.slice(0, -1);
    }
  };

  // ../nizel/dist/parse/inline.js
  var parseInline = (source, options = { autolinks: true }) => parseInlineWithState(source, options, { references: /* @__PURE__ */ new Map() });
  var parseInlineWithState = (source, options = { autolinks: true }, state, extractNestedLinks = true) => {
    const autolinks = options.autolinks !== false && getAutolinkOptions(options.autolinks).enabled !== false;
    if (!hasInlineSyntax(source, autolinks)) {
      return source ? [{ type: "text", value: source }] : [];
    }
    if (extractNestedLinks && hasBalancedLinkCandidate(source)) {
      const scanned = scanBalancedInlineLinks(source, options, state);
      if (scanned)
        return resolveRemainingEmphasis(scanned);
    }
    const nodes = [];
    const safe = options.safe !== false;
    const pattern = new RegExp("(?<inlineHtml><!-->|<!--->|<!--[\\s\\S]*?-->|<\\?[\\s\\S]*?\\?>|<![A-Z][^>]*>|<!\\[CDATA\\[[\\s\\S]*?\\]\\]>|<\\/?[A-Za-z][A-Za-z0-9-]*(?:\\s+[A-Za-z_:][A-Za-z0-9_.:-]*(?:\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s\"'=<>`]+))?)*\\s*\\/?>)|(?<hardSpaces> {2,}\\n)|(?<hardBackslash>\\\\\\n)|(?<softBreak>\\n)|(?<!`)(?<codeTicks>`+)(?!`)(?<codeValue>[\\s\\S]*?)(?<!`)\\k<codeTicks>(?!`)|\\\\(?<escaped>[!\"#$%&'()*+,\\-./:;<=>?@[\\\\\\]^_`{|}~])|&(?<entity>[A-Za-z][A-Za-z0-9]+|#[0-9]+|#[xX][0-9A-Fa-f]+);|!\\[(?<refImageAlt>[^\\]]*)\\]\\[(?<refImageLabel>[^\\]]*)\\]|\\[(?<refLinkText>[^\\]`<\\[]+)\\]\\[(?<refLinkLabel>[^\\]]*)\\]|!\\[(?<inlineImageAlt>[^\\]`<]*)\\]\\([ \\t\\n]*(?<inlineImageHref><[^<>\\n\\\\]*>|(?!<)(?:\\\\.|[^() \\t\\n`\\\\]|\\([^()\\n]*(?:\\([^()\\n]*\\)[^()\\n]*)*\\))*)(?:[ \\t\\n]+(?:\"(?<inlineImageTitle>(?:\\\\.|[^\"`])*)\"|'(?<inlineImageTitleSingle>[^']*)'|\\((?<inlineImageTitleParen>[^)]*)\\)))?[ \\t\\n]*\\)|\\[(?<inlineLinkText>[^\\]`<]*)\\]\\([ \\t\\n]*(?<inlineLinkHref><[^<>\\n\\\\]*>|(?!<)(?:\\\\.|[^() \\t\\n`\\\\]|\\([^()\\n]*(?:\\([^()\\n]*\\)[^()\\n]*)*\\))*)(?:[ \\t\\n]+(?:\"(?<inlineLinkTitle>(?:\\\\.|[^\"`])*)\"|'(?<inlineLinkTitleSingle>[^']*)'|\\((?<inlineLinkTitleParen>[^)]*)\\)))?[ \\t\\n]*\\)|<(?<angleUrl>[A-Za-z][A-Za-z0-9+.-]{1,31}:[^<>\\s]*)>|<(?<angleEmail>[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?(?:\\.[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?)*)>|!\\[(?<shortcutImageAlt>(?:\\\\\\]|[^\\]`<\\[])+)\\]|\\[(?<shortcutLinkText>(?:\\\\\\]|[^\\]`<\\[])+)\\]|~~(?<deleteValue>[^~`]+)~~|(?<bareUrl>https?:\\/\\/[^\\s<`]+)|(?<bareEmail>[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,})", "giu");
    let lastIndex = 0;
    let match;
    while (match = pattern.exec(source)) {
      if (match.index > lastIndex) {
        nodes.push({ type: "text", value: source.slice(lastIndex, match.index) });
      }
      const groups = match.groups ?? {};
      if (groups.inlineHtml !== void 0) {
        nodes.push(safe || !isValidInlineHtmlToken(groups.inlineHtml) ? { type: "text", value: groups.inlineHtml } : { type: "inlineHtml", value: groups.inlineHtml });
      } else if (groups.hardSpaces !== void 0 || groups.hardBackslash !== void 0) {
        nodes.push({ type: "lineBreak", hard: true });
      } else if (groups.softBreak !== void 0) {
        trimTrailingSoftBreakSpace(nodes);
        nodes.push({ type: "lineBreak", value: " " });
      } else if (groups.codeValue !== void 0) {
        nodes.push({ type: "inlineCode", code: normalizeCodeSpan(groups.codeValue) });
      } else if (groups.escaped !== void 0) {
        nodes.push({ type: "text", value: groups.escaped, escaped: true });
      } else if (groups.entity !== void 0) {
        nodes.push({ type: "text", value: decodeEntity(groups.entity), escaped: true });
      } else if (groups.refImageAlt !== void 0) {
        const reference = state.references.get(normalizeReferenceLabelForLookup(groups.refImageLabel || groups.refImageAlt));
        if (reference) {
          nodes.push({
            type: "image",
            alt: stripInlineMarkdown(groups.refImageAlt, options),
            src: reference.href,
            title: reference.title
          });
        } else {
          nodes.push({ type: "text", value: decodeStringContent(match[0]) });
        }
      } else if (groups.refLinkText !== void 0) {
        const reference = state.references.get(normalizeReferenceLabelForLookup(groups.refLinkLabel || groups.refLinkText));
        if (reference) {
          nodes.push({
            type: "link",
            href: reference.href,
            title: reference.title,
            external: isExternalHref(reference.href),
            children: parseInlineWithState(groups.refLinkText, options, state)
          });
        } else {
          nodes.push({ type: "text", value: decodeStringContent(match[0]) });
        }
      } else if (groups.inlineImageAlt !== void 0) {
        nodes.push({
          type: "image",
          alt: stripInlineMarkdown(groups.inlineImageAlt, options),
          src: normalizeHref(decodeStringContent(normalizeInlineDestination(groups.inlineImageHref))),
          title: inlineTitleFromGroups(groups, "inlineImageTitle")
        });
      } else if (groups.inlineLinkText !== void 0) {
        const href = normalizeHref(decodeStringContent(normalizeInlineDestination(groups.inlineLinkHref)));
        nodes.push({
          type: "link",
          href,
          title: inlineTitleFromGroups(groups, "inlineLinkTitle"),
          external: isExternalHref(href),
          children: parseInlineWithState(groups.inlineLinkText, options, state)
        });
      } else if (groups.angleUrl !== void 0) {
        const href = normalizeHref(groups.angleUrl);
        nodes.push({
          type: "link",
          href,
          external: isExternalHref(href),
          children: [{ type: "text", value: groups.angleUrl }]
        });
      } else if (groups.angleEmail !== void 0) {
        nodes.push({
          type: "link",
          href: `mailto:${groups.angleEmail}`,
          external: false,
          children: [{ type: "text", value: groups.angleEmail }]
        });
      } else if (groups.shortcutImageAlt !== void 0) {
        const alt = decodeStringContent(groups.shortcutImageAlt);
        const reference = state.references.get(normalizeReference(alt));
        if (reference) {
          nodes.push({
            type: "image",
            alt: stripInlineMarkdown(alt, options),
            src: reference.href,
            title: reference.title
          });
        } else {
          nodes.push({ type: "text", value: decodeStringContent(match[0]) });
        }
      } else if (groups.shortcutLinkText !== void 0) {
        const text = decodeStringContent(groups.shortcutLinkText);
        const reference = state.references.get(normalizeReference(text));
        if (reference) {
          nodes.push({
            type: "link",
            href: reference.href,
            title: reference.title,
            external: isExternalHref(reference.href),
            children: parseInlineWithState(text, options, state)
          });
        } else {
          nodes.push({ type: "text", value: decodeStringContent(match[0]) });
        }
      } else if (groups.deleteValue !== void 0) {
        nodes.push({ type: "delete", children: parseInlineWithState(groups.deleteValue, options, state) });
      } else if (groups.strongStarValue !== void 0 || groups.strongUnderscoreValue !== void 0) {
        nodes.push({
          type: "strong",
          children: parseInlineWithState(groups.strongStarValue ?? groups.strongUnderscoreValue, options, state)
        });
      } else if (groups.emStarValue !== void 0 || groups.emUnderscoreValue !== void 0) {
        nodes.push({
          type: "emphasis",
          children: parseInlineWithState(groups.emStarValue ?? groups.emUnderscoreValue, options, state)
        });
      } else if (groups.bareUrl !== void 0 && autolinks) {
        const href = trimTrailingPunctuation(groups.bareUrl);
        nodes.push({
          type: "link",
          href,
          external: true,
          children: [{ type: "text", value: href }]
        });
        const trailing = groups.bareUrl.slice(href.length);
        if (trailing)
          nodes.push({ type: "text", value: trailing });
      } else if (groups.bareEmail !== void 0 && autolinks) {
        nodes.push({
          type: "link",
          href: `mailto:${groups.bareEmail}`,
          external: false,
          children: [{ type: "text", value: groups.bareEmail }]
        });
      } else {
        nodes.push({ type: "text", value: match[0] });
      }
      lastIndex = pattern.lastIndex;
    }
    if (lastIndex < source.length)
      nodes.push({ type: "text", value: source.slice(lastIndex) });
    return resolveRemainingEmphasis(nodes);
  };
  var hasInlineSyntax = (source, autolinks) => {
    if (!source)
      return false;
    if (/[\\`<&\n\[\]*_~]/.test(source))
      return true;
    return autolinks && (source.includes("http://") || source.includes("https://") || source.includes("@"));
  };
  var hasBalancedLinkCandidate = (source) => {
    return source.includes("[");
  };
  var scanBalancedInlineLinks = (source, options, state) => {
    const nodes = [];
    let cursor = 0;
    let searchStart = 0;
    let found = false;
    while (cursor < source.length) {
      const opener = nextInlineLabelOpener(source, searchStart);
      if (opener === -1)
        break;
      const image = source[opener] === "!";
      const labelStart = opener + (image ? 2 : 1);
      const labelEnd = findBalancedLabelEnd(source, labelStart);
      if (labelEnd === -1) {
        searchStart = opener + 1;
        continue;
      }
      const label = source.slice(labelStart, labelEnd);
      if (!image && containsInlineLink(label)) {
        searchStart = opener + 1;
        continue;
      }
      const inlineDestination = source[labelEnd + 1] === "(" ? readInlineDestination(source, labelEnd + 1) : null;
      const referenceDestination = inlineDestination ? null : readInlineReferenceDestination(source, labelEnd, label, state);
      const href = inlineDestination?.href ?? referenceDestination?.href;
      if (href === void 0) {
        const unresolvedReferenceEnd = inlineDestination ? -1 : readUnresolvedInlineReferenceEnd(source, labelEnd);
        if (!image && unresolvedReferenceEnd !== -1) {
          const referenceLabel = source.slice(labelEnd + 2, unresolvedReferenceEnd);
          if (opener > cursor) {
            nodes.push(...parseInlineWithState(source.slice(cursor, opener), options, state, false));
          }
          nodes.push({ type: "text", value: "[" });
          nodes.push(...parseInlineWithState(label, options, state, false));
          nodes.push({ type: "text", value: "]" });
          if (!canTailBecomeReferenceLink(source, unresolvedReferenceEnd, referenceLabel, state)) {
            nodes.push({ type: "text", value: "[" });
            nodes.push(...parseInlineWithState(referenceLabel, options, state, false));
            nodes.push({ type: "text", value: "]" });
            cursor = unresolvedReferenceEnd + 1;
          } else {
            cursor = labelEnd + 1;
          }
          found = true;
          searchStart = unresolvedReferenceEnd + 1;
          continue;
        }
        searchStart = opener + 1;
        continue;
      }
      const title = inlineDestination?.title ?? referenceDestination?.title;
      const endIndex = inlineDestination?.endIndex ?? referenceDestination?.endIndex;
      if (endIndex === void 0) {
        searchStart = opener + 1;
        continue;
      }
      if (opener > cursor) {
        nodes.push(...parseInlineWithState(source.slice(cursor, opener), options, state, false));
      }
      if (image) {
        nodes.push({
          type: "image",
          alt: stripInlineMarkdown(label, options),
          src: normalizeHref(decodeStringContent(href)),
          title: title === void 0 ? void 0 : decodeStringContent(title)
        });
      } else {
        const normalizedHref = normalizeHref(decodeStringContent(href));
        nodes.push({
          type: "link",
          href: normalizedHref,
          title: title === void 0 ? void 0 : decodeStringContent(title),
          external: isExternalHref(normalizedHref),
          children: parseInlineWithState(label, options, state, false)
        });
      }
      found = true;
      cursor = endIndex + 1;
      searchStart = cursor;
    }
    if (!found)
      return null;
    if (cursor < source.length) {
      nodes.push(...parseInlineWithState(source.slice(cursor), options, state, false));
    }
    return nodes;
  };
  var stripInlineMarkdown = (source, options = { autolinks: true }) => stripInlineNodes(parseInline(source, options));

  // ../nizel/dist/parse/lines.js
  var expandLeadingTabsToLines = (markdown) => {
    return markdown.split("\n").map((line) => expandLeadingTabsInLine(line));
  };
  var expandLeadingTabsInLine = (line) => {
    let result = "";
    let column = 0;
    let cursor = 0;
    while (cursor < line.length) {
      const character = line[cursor];
      if (character === "	") {
        const spaces = 4 - column % 4;
        result += " ".repeat(spaces);
        column += spaces;
        cursor += 1;
        continue;
      }
      result += character;
      column += 1;
      cursor += 1;
      if (character !== " ")
        break;
    }
    return result + line.slice(cursor);
  };
  var expandLeadingTabsFromColumn = (line, startColumn) => {
    let result = "";
    let column = startColumn;
    let inLeadingIndent = true;
    for (const character of line) {
      if (character === "	" && inLeadingIndent) {
        const spaces = 4 - column % 4;
        result += " ".repeat(spaces);
        column += spaces;
        continue;
      }
      result += character;
      column += 1;
      if (character !== " ")
        inLeadingIndent = false;
    }
    return result;
  };
  var nextNonBlankLine = (lines, startIndex) => {
    for (let index = startIndex; index < lines.length; index += 1) {
      if (lines[index].trim())
        return index;
    }
    return -1;
  };
  var countLeadingSpaces = (line) => {
    let count = 0;
    while (line[count] === " ") {
      count += 1;
    }
    return count;
  };
  var trimTrailingBlankLines = (lines) => {
    const result = [...lines];
    while (result.length > 0 && !result[result.length - 1].trim())
      result.pop();
    return result;
  };

  // ../nizel/dist/parse/list-items.js
  var parseListItemBlocks = (firstLine, lines, index, openingListMarker, contentIndent, options, seenSlugs, state, parseBlocks2, isBlockStart2) => {
    const itemLines = [firstLine];
    let cursor = index + 1;
    let loose = false;
    let sawBlank = false;
    let openFence = openingFenceClosePattern(firstLine);
    while (cursor < lines.length) {
      const marker = parseListMarker(lines[cursor]);
      if (marker && marker.ordered === openingListMarker.ordered && isSameListMarker(openingListMarker, marker) && countLeadingSpaces(lines[cursor]) < contentIndent) {
        break;
      }
      if (!lines[cursor].trim()) {
        if (openFence) {
          itemLines.push("");
          cursor += 1;
          continue;
        }
        const nextContentIndex = nextNonBlankLine(lines, cursor + 1);
        if (nextContentIndex === -1)
          break;
        const nextMarker = parseListMarker(lines[nextContentIndex]);
        if (nextMarker && nextMarker.ordered === openingListMarker.ordered && isSameListMarker(openingListMarker, nextMarker) && countLeadingSpaces(lines[nextContentIndex]) < contentIndent) {
          itemLines.push("");
          loose = true;
          sawBlank = true;
          cursor += 1;
          continue;
        }
        if (cursor === index + 1 && firstLine === "")
          break;
        const nextIndent = countLeadingSpaces(lines[nextContentIndex]);
        if (nextIndent < contentIndent)
          break;
        itemLines.push("");
        loose = !hasNestedListMarkerBeforeBlank(itemLines, nextIndent - contentIndent);
        sawBlank = true;
        cursor += 1;
        continue;
      }
      if (countLeadingSpaces(lines[cursor]) >= contentIndent) {
        const itemLine = lines[cursor].slice(contentIndent);
        itemLines.push(itemLine);
        openFence = updateOpenFence(openFence, itemLine);
        cursor += 1;
        continue;
      }
      if (!sawBlank && !isBlockStart2(lines[cursor], options, lines, cursor)) {
        itemLines.push(lines[cursor]);
        openFence = updateOpenFence(openFence, lines[cursor]);
        cursor += 1;
        continue;
      }
      break;
    }
    while (itemLines.length > 0 && itemLines[itemLines.length - 1] === "") {
      itemLines.pop();
    }
    return {
      children: parseBlocks2(itemLines, options, seenSlugs, state),
      endIndex: cursor - 1,
      loose
    };
  };
  var hasNestedListMarkerBeforeBlank = (itemLines, relativeNextIndent) => {
    return itemLines.some((itemLine) => {
      const marker = parseListMarker(itemLine);
      return marker !== null && countLeadingSpaces(itemLine) < relativeNextIndent;
    });
  };
  var updateOpenFence = (openFence, line) => {
    if (openFence)
      return openFence.test(line) ? null : openFence;
    return openingFenceClosePattern(line);
  };

  // ../nizel/dist/parse/references.js
  var extractReferenceDefinitions = (lines) => {
    const references = /* @__PURE__ */ new Map();
    const contentLines = [];
    let previousWasReference = false;
    for (let index = 0; index < lines.length; index += 1) {
      const htmlBlock = readHtmlBlock(lines, index);
      if (htmlBlock) {
        contentLines.push(...lines.slice(index, htmlBlock.endIndex + 1));
        index = htmlBlock.endIndex;
        previousWasReference = false;
        continue;
      }
      const fence = /^ {0,3}(`{3,}|~{3,})/.exec(lines[index]);
      if (fence) {
        const marker = fence[1][0];
        const close = new RegExp(`^ {0,3}\\${marker}{${fence[1].length},}\\s*$`);
        contentLines.push(lines[index]);
        index += 1;
        while (index < lines.length) {
          contentLines.push(lines[index]);
          if (close.test(lines[index]))
            break;
          index += 1;
        }
        previousWasReference = false;
        continue;
      }
      if (/^ {4}/.test(lines[index])) {
        contentLines.push(lines[index]);
        previousWasReference = false;
        continue;
      }
      const blockquoteReference = /^>\s?(.*)$/.exec(lines[index]);
      if (blockquoteReference) {
        const parsed2 = readReferenceDefinition([blockquoteReference[1]], 0);
        if (parsed2) {
          const label2 = normalizeReference(parsed2.label);
          if (!references.has(label2))
            references.set(label2, parsed2.reference);
          contentLines.push(">");
          previousWasReference = true;
          continue;
        }
      }
      const canStartReference = index === 0 || !lines[index - 1].trim() || previousWasReference || isReferenceStartAfterBlock(lines[index - 1]);
      if (!canStartReference) {
        contentLines.push(lines[index]);
        previousWasReference = false;
        continue;
      }
      const parsed = readReferenceDefinition(lines, index);
      if (!parsed) {
        contentLines.push(lines[index]);
        previousWasReference = false;
        continue;
      }
      const label = normalizeReference(parsed.label);
      if (!references.has(label))
        references.set(label, parsed.reference);
      index = parsed.endIndex;
      previousWasReference = true;
    }
    return { contentLines, references };
  };
  var readReferenceDefinition = (lines, startIndex) => {
    const multiline = readMultilineReferenceDefinition(lines, startIndex);
    if (multiline)
      return multiline;
    const opener = /^ {0,3}\[((?:\\[!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~]|[^\[\]\n]){1,999})\]:[ \t]*(.*)$/.exec(lines[startIndex]);
    if (!opener)
      return null;
    const parts = [opener[2]];
    let cursor = startIndex + 1;
    while (cursor < lines.length && lines[cursor].trim() && canContinueReferenceDefinition(parts, lines[cursor])) {
      parts.push(lines[cursor]);
      cursor += 1;
    }
    const reference = parseReferenceDefinitionContent(parts.join("\n"));
    if (!reference)
      return null;
    return {
      label: decodeStringContent(opener[1]),
      reference,
      endIndex: cursor - 1
    };
  };
  var readMultilineReferenceDefinition = (lines, startIndex) => {
    const opener = /^ {0,3}\[((?:\\[!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~]|[^\[\]\n])*)$/.exec(lines[startIndex]);
    if (!opener)
      return null;
    const labelParts = [opener[1]];
    for (let cursor = startIndex + 1; cursor < lines.length; cursor += 1) {
      const closer = /^ {0,3}((?:\\[!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~]|[^\[\]\n])*)\]:[ \t]*(.*)$/.exec(lines[cursor]);
      if (!closer) {
        if (!lines[cursor].trim())
          return null;
        labelParts.push(lines[cursor]);
        continue;
      }
      const label = labelParts.concat(closer[1]).join("\n");
      if (!label.trim() || label.length > 999)
        return null;
      const parts = [closer[2]];
      let contentCursor = cursor + 1;
      while (contentCursor < lines.length && lines[contentCursor].trim() && canContinueReferenceDefinition(parts, lines[contentCursor])) {
        parts.push(lines[contentCursor]);
        contentCursor += 1;
      }
      const reference = parseReferenceDefinitionContent(parts.join("\n"));
      if (!reference)
        return null;
      return {
        label: decodeStringContent(label),
        reference,
        endIndex: contentCursor - 1
      };
    }
    return null;
  };
  var canContinueReferenceDefinition = (parts, line) => {
    const collected = parts.join("\n").trim();
    if (!collected)
      return true;
    if (/^ {1,}/.test(line))
      return true;
    if (hasOpenReferenceTitle(parts))
      return true;
    const parsed = parseReferenceDefinitionContent(collected);
    return parsed?.title === void 0 && /^["'(]/.test(line.trim()) && parseReferenceDefinitionContent(`${collected}
${line}`) !== null;
  };
  var isReferenceStartAfterBlock = (line) => {
    return /^ {0,3}(#{1,6})(?:\s|$)/.test(line) || isThematicBreak2(line);
  };
  var parseReferenceDefinitionContent = (content) => {
    let rest = content.trim();
    if (!rest)
      return null;
    let destination = "";
    if (rest.startsWith("<")) {
      const closeIndex = rest.indexOf(">");
      if (closeIndex === -1)
        return null;
      destination = rest.slice(1, closeIndex);
      rest = rest.slice(closeIndex + 1);
      if (rest && !/^\s/.test(rest))
        return null;
    } else {
      const destinationMatch = /^\S+/.exec(rest);
      if (!destinationMatch)
        return null;
      destination = destinationMatch[0];
      rest = rest.slice(destination.length);
    }
    const title = parseReferenceTitle(rest);
    if (title === null)
      return null;
    return {
      href: normalizeHref(decodeStringContent(destination)),
      title: title === void 0 ? void 0 : decodeStringContent(title)
    };
  };
  var parseReferenceTitle = (source) => {
    const rest = source.trim();
    if (!rest)
      return void 0;
    const opener = rest[0];
    const closer = opener === "(" ? ")" : opener;
    if (!['"', "'", "("].includes(opener))
      return null;
    if (!rest.endsWith(closer))
      return null;
    return rest.slice(1, -1);
  };
  var hasOpenReferenceTitle = (parts) => {
    const content = parts.join("\n").trim();
    const destination = /^<?\S+>?/.exec(content);
    if (!destination)
      return false;
    const rest = content.slice(destination[0].length).trimStart();
    if (!rest)
      return false;
    const opener = rest[0];
    const closer = opener === "(" ? ")" : opener;
    return ['"', "'", "("].includes(opener) && (rest.length === 1 || !rest.endsWith(closer));
  };
  var isThematicBreak2 = (line) => {
    return /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/.test(line);
  };

  // ../nizel/dist/parse.js
  function parseMarkdown(markdown, options) {
    const normalizedMarkdown = markdown.includes("\r") ? markdown.replace(/\r\n?/g, "\n") : markdown;
    const lines = normalizedMarkdown.includes("	") ? expandLeadingTabsToLines(normalizedMarkdown) : normalizedMarkdown.split("\n");
    const { contentLines, references } = normalizedMarkdown.includes("[") && hasPossibleReferenceDefinitionStart(normalizedMarkdown) ? extractReferenceDefinitions(lines) : { contentLines: lines, references: /* @__PURE__ */ new Map() };
    const children = parseBlocks(contentLines, options, /* @__PURE__ */ new Map(), { references });
    return { type: "root", children };
  }
  var hasPossibleReferenceDefinitionStart = (markdown) => {
    return /(^|\n)(?: {0,3}> ?| {0,3})\[/.test(markdown);
  };
  function parseBlocks(lines, options, seenSlugs, state) {
    const children = [];
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index];
      if (!line.trim())
        continue;
      if (!options.safe) {
        const htmlBlock = readHtmlBlock(lines, index);
        if (htmlBlock) {
          children.push({ type: "html", value: htmlBlock.value });
          index = htmlBlock.endIndex;
          continue;
        }
      }
      const customBlock = /^::([A-Za-z][\w-]*)(?:\s+(.*))?$/.exec(line.trim());
      if (customBlock) {
        const parsed = readCustomBlock(lines, index);
        const args = splitWords(customBlock[2] ?? "");
        const definition = options.blocks[customBlock[1]];
        const value = definition?.parse?.({
          name: customBlock[1],
          args,
          props: parsed.props,
          content: parsed.content
        });
        children.push({
          type: "customBlock",
          name: customBlock[1],
          args,
          props: parsed.props,
          value,
          children: parseBlocks(parsed.content.split("\n"), options, seenSlugs, state)
        });
        index = parsed.endIndex;
        continue;
      }
      const fence = /^( {0,3})(`{3,}|~{3,})[ \t]*(.*)$/.exec(line);
      if (fence) {
        const code = [];
        const indent = fence[1].length;
        const markerRun = fence[2];
        const marker = markerRun[0];
        const close = new RegExp(`^ {0,3}\\${marker}{${markerRun.length},}\\s*$`);
        const info = parseFenceInfo(fence[3] ?? "", marker);
        if (!info.valid) {
        } else {
          index += 1;
          while (index < lines.length && !close.test(lines[index])) {
            code.push(stripFenceIndent(lines[index], indent));
            index += 1;
          }
          if (index >= lines.length && code[code.length - 1] === "")
            code.pop();
          const metadata = parseCodeMeta(info.meta);
          children.push({
            type: "code",
            code: code.length > 0 ? `${code.join("\n")}
` : "",
            lang: info.lang,
            meta: info.meta || void 0,
            filename: metadata.filename,
            highlightLines: metadata.highlightLines
          });
          continue;
        }
      }
      if (/^ {4}/.test(line)) {
        const code = [];
        while (index < lines.length && (/^ {4}/.test(lines[index]) || !lines[index].trim())) {
          code.push(lines[index].replace(/^ {0,4}/, ""));
          index += 1;
        }
        index -= 1;
        const trimmedCode = trimTrailingBlankLines(code);
        children.push({ type: "code", code: trimmedCode.length > 0 ? `${trimmedCode.join("\n")}
` : "" });
        continue;
      }
      if (isThematicBreak(line)) {
        children.push({ type: "thematicBreak" });
        continue;
      }
      const heading = /^ {0,3}(#{1,6})(?:\s+(.*?))?\s*$/.exec(line);
      if (heading) {
        const source = trimClosingHeadingHashes(heading[2] ?? "");
        const inlineChildren = parseInlineWithState(source, options, state);
        const text = stripInlineNodes(inlineChildren);
        const node = {
          type: "heading",
          depth: heading[1].length,
          text,
          children: inlineChildren
        };
        if (options.anchors && text)
          node.id = uniqueSlug(slugify(text, options.slugStyle), seenSlugs);
        children.push(node);
        continue;
      }
      const setext = lines[index + 1] && isSetextUnderline(lines[index + 1]);
      if (setext && line.trim() && !isBlockStart(line, options, lines, index)) {
        const source = line.trim();
        const inlineChildren = parseInlineWithState(source, options, state);
        const text = stripInlineNodes(inlineChildren);
        const node = {
          type: "heading",
          depth: setext[1][0] === "=" ? 1 : 2,
          text,
          children: inlineChildren
        };
        if (options.anchors && text)
          node.id = uniqueSlug(slugify(text, options.slugStyle), seenSlugs);
        children.push(node);
        index += 1;
        continue;
      }
      if (isTableStart(lines, index)) {
        const parsed = readTable(lines, index, options, parseInline);
        children.push(parsed.table);
        index = parsed.endIndex;
        continue;
      }
      if (/^ {0,3}> ?/.test(line)) {
        const quoteLines = [];
        let allowLazyContinuation = false;
        while (index < lines.length) {
          const quoteMarker = /^( {0,3}> ?)(.*)$/.exec(lines[index]);
          if (quoteMarker) {
            const markerColumn = quoteMarker[1].endsWith(" ") ? quoteMarker[1].length : quoteMarker[1].length + 1;
            const quoteLine = expandLeadingTabsFromColumn(quoteMarker[2], markerColumn);
            quoteLines.push(quoteLine);
            allowLazyContinuation = canStartLazyBlockquoteContinuation(quoteLine, options, quoteLines, quoteLines.length - 1, isBlockStart);
            index += 1;
            continue;
          }
          if (allowLazyContinuation && canContinueBlockquoteLazily(lines[index], options, lines, index)) {
            quoteLines.push(isSetextUnderline(lines[index]) ? `\\${lines[index]}` : lines[index]);
            allowLazyContinuation = true;
            index += 1;
            continue;
          }
          break;
        }
        if (quoteLines[quoteLines.length - 1] === "") {
          quoteLines.pop();
        }
        if (index > 0) {
          index -= 1;
        } else {
          index += 1;
        }
        children.push({
          type: "blockquote",
          children: parseBlocks(quoteLines, options, seenSlugs, state)
        });
        continue;
      }
      const openingListMarker = parseListMarker(line);
      if (openingListMarker) {
        const items = [];
        const ordered = openingListMarker.ordered;
        const start = openingListMarker.start;
        let tight = true;
        while (index < lines.length) {
          if (items.length > 0 && isThematicBreak(lines[index]))
            break;
          const marker = parseListMarker(lines[index]);
          if (!marker || marker.ordered !== ordered || !isSameListMarker(openingListMarker, marker)) {
            break;
          }
          const body = marker.body;
          const checked = /^\[[ xX]\]\s+/.test(body) ? /^\[[xX]\]\s+/.test(body) : void 0;
          const cleanBody = body.replace(/^\[[ xX]\]\s+/, "");
          const parsedItem = parseListItemBlocks(cleanBody, lines, index, openingListMarker, marker.contentIndent, options, seenSlugs, state, parseBlocks, isBlockStart);
          if (parsedItem.loose)
            tight = false;
          items.push({
            type: "listItem",
            checked,
            children: parsedItem.children
          });
          index = parsedItem.endIndex + 1;
        }
        index -= 1;
        children.push({ type: "list", ordered, start, tight, children: items });
        continue;
      }
      const paragraph = [normalizeParagraphLine(line)];
      while (index + 1 < lines.length && canContinueParagraph(lines[index + 1], lines, index + 1, options)) {
        index += 1;
        paragraph.push(normalizeParagraphLine(lines[index]));
      }
      const paragraphSetext = lines[index + 1] && isSetextUnderline(lines[index + 1]);
      if (paragraphSetext) {
        const source = normalizeParagraphSource(paragraph);
        const inlineChildren = parseInlineWithState(source, options, state);
        const text = stripInlineNodes(inlineChildren);
        const node = {
          type: "heading",
          depth: paragraphSetext[1][0] === "=" ? 1 : 2,
          text,
          children: inlineChildren
        };
        if (options.anchors && text)
          node.id = uniqueSlug(slugify(text, options.slugStyle), seenSlugs);
        children.push(node);
        index += 1;
        continue;
      }
      children.push({
        type: "paragraph",
        children: parseInlineWithState(normalizeParagraphSource(paragraph), options, state)
      });
    }
    return children;
  }
  function canContinueParagraph(line, lines, index, options) {
    if (!line.trim())
      return false;
    if (!hasParagraphInterruptCandidate(line, options))
      return true;
    return Boolean(!isSetextUnderline(line) && !isThematicBreak(line) && !/^(#{1,6})\s+/.test(line) && !/^ {0,3}(`{3,}|~{3,})/.test(line) && !/^::[A-Za-z][\w-]*/.test(line.trim()) && !isParagraphInterruptingListMarker(line) && !/^ {0,3}> ?/.test(line) && !(options.safe === false && isInterruptingHtmlBlockStart(line)) && !isTableStart(lines, index));
  }
  function hasParagraphInterruptCandidate(line, options) {
    const trimmedStart = line.trimStart();
    const first = trimmedStart[0];
    if (line.includes("|"))
      return true;
    if (options.safe === false && first === "<")
      return true;
    return first !== void 0 && "#`~:->*+=0123456789".includes(first);
  }
  function isBlockStart(line, options, lines, index) {
    return Boolean(/^ {0,3}(#{1,6})(?:\s|$)/.test(line) || /^ {0,3}(`{3,}|~{3,})/.test(line) || isThematicBreak(line) || /^ {0,3}> ?/.test(line) || parseListMarker(line) || isTableStart(lines, index) || !options.safe && isRawHtmlBlockLine(line));
  }

  // ../nizel/dist/render.js
  function renderHtml(ast, elements, blocks = {}, options = {}) {
    if (isEmptyObject(elements) && isEmptyObject(blocks) && options.unwrapStandaloneImages !== true) {
      return ast.children.map(renderBlockFast).join("\n");
    }
    return ast.children.map((node) => renderBlock(node, elements, blocks, options)).join("\n");
  }
  function isEmptyObject(value) {
    for (const _key in value)
      return false;
    return true;
  }
  function renderBlockFast(node) {
    if (node.type === "heading") {
      return wrap(`h${node.depth}`, renderInlineFast(node.children), { id: node.id });
    }
    if (node.type === "paragraph")
      return wrap("p", renderInlineFast(node.children));
    if (node.type === "code") {
      const code = wrap("code", escapeHtml(node.code), {
        class: node.lang ? `language-${node.lang}` : void 0,
        "data-filename": node.filename,
        "data-highlight-lines": node.highlightLines?.join(",")
      });
      return wrap("pre", code);
    }
    if (node.type === "list") {
      const tag = node.ordered ? "ol" : "ul";
      const items = node.children.map((item) => wrap("li", renderListItemChildrenFast(item.children, node.tight === true), { "data-checked": item.checked })).join("\n");
      return wrap(tag, `
${items}
`, { start: node.start !== void 0 && node.start !== 1 ? node.start : void 0 });
    }
    if (node.type === "blockquote") {
      const body = node.children.length > 0 ? `
${node.children.map(renderBlockFast).join("\n")}
` : "\n";
      return wrap("blockquote", body);
    }
    if (node.type === "table") {
      const [header, ...rows] = node.children;
      const head = header ? wrap("thead", wrap("tr", header.children.map((cell, index) => wrap("th", renderInlineFast(cell.children), tableCellAttrs(node.align?.[index]))).join(""))) : "";
      const body = wrap("tbody", rows.map((row) => wrap("tr", row.children.map((cell, index) => wrap("td", renderInlineFast(cell.children), tableCellAttrs(node.align?.[index]))).join(""))).join(""));
      return wrap("table", head + body);
    }
    if (node.type === "thematicBreak")
      return "<hr />";
    if (node.type === "html")
      return node.value;
    if (node.type === "customBlock") {
      return wrap("div", (node.children ?? []).map(renderBlockFast).join("\n"), { "data-nizel-block": node.name });
    }
    return "";
  }
  function renderBlock(node, elements, blocks, options) {
    if (node.type === "heading") {
      const tag = `h${node.depth}`;
      return wrap(resolveTag(tag, node, elements), renderInline(node.children, elements), {
        id: node.id,
        ...attrsFor(tag, node, elements)
      });
    }
    if (node.type === "paragraph") {
      if (options.unwrapStandaloneImages && isStandaloneImageParagraph(node.children)) {
        return renderInline(node.children, elements);
      }
      return wrap(resolveTag("p", node, elements), renderInline(node.children, elements), attrsFor("p", node, elements));
    }
    if (node.type === "code") {
      const renderer = blocks.code?.formats?.html;
      if (renderer) {
        return renderer(node, {
          render(nodes) {
            return Array.isArray(nodes) && nodes[0] && isInline2(nodes[0]) ? renderInline(nodes, elements) : nodes.map((child) => renderBlock(child, elements, blocks, options)).join("\n");
          },
          escape: escapeHtml
        });
      }
      const code = wrap(resolveTag("code", node, elements), escapeHtml(node.code), {
        class: node.lang ? `language-${node.lang}` : void 0,
        "data-filename": node.filename,
        "data-highlight-lines": node.highlightLines?.join(",")
      });
      return wrap(resolveTag("pre", node, elements), code, attrsFor("pre", node, elements));
    }
    if (node.type === "list") {
      const tag = node.ordered ? "ol" : "ul";
      const items = node.children.map((item) => wrap(resolveTag("li", item, elements), renderListItemChildren(item.children, node.tight === true, elements, blocks, options), {
        "data-checked": item.checked,
        ...attrsFor("li", item, elements)
      })).join("\n");
      return wrap(resolveTag(tag, node, elements), `
${items}
`, {
        start: node.start !== void 0 && node.start !== 1 ? node.start : void 0,
        ...attrsFor(tag, node, elements)
      });
    }
    if (node.type === "blockquote") {
      return wrap(resolveTag("blockquote", node, elements), node.children.length > 0 ? `
${node.children.map((child) => renderBlock(child, elements, blocks, options)).join("\n")}
` : "\n", attrsFor("blockquote", node, elements));
    }
    if (node.type === "table") {
      const [header, ...rows] = node.children;
      const head = header ? wrap(resolveTag("thead", header, elements), wrap(resolveTag("tr", header, elements), header.children.map((cell, index) => wrap(resolveTag("th", cell, elements), renderInline(cell.children, elements), tableCellAttrs(node.align?.[index]))).join(""))) : "";
      const body = wrap(resolveTag("tbody", node, elements), rows.map((row) => wrap(resolveTag("tr", row, elements), row.children.map((cell, index) => wrap(resolveTag("td", cell, elements), renderInline(cell.children, elements), tableCellAttrs(node.align?.[index]))).join(""))).join(""));
      return wrap(resolveTag("table", node, elements), head + body, attrsFor("table", node, elements));
    }
    if (node.type === "thematicBreak")
      return `<hr${serializeAttrs(attrsFor("hr", node, elements))} />`;
    if (node.type === "html")
      return node.value;
    if (node.type === "customBlock") {
      const renderer = blocks[node.name]?.formats?.html;
      if (renderer) {
        return renderer(node, {
          render(nodes) {
            return Array.isArray(nodes) && nodes[0] && isInline2(nodes[0]) ? renderInline(nodes, elements) : nodes.map((child) => renderBlock(child, elements, blocks, options)).join("\n");
          },
          escape: escapeHtml
        });
      }
      return wrap(resolveTag("div", node, elements), (node.children ?? []).map((child) => renderBlock(child, elements, blocks, options)).join("\n"), {
        "data-nizel-block": node.name,
        ...attrsFor(node.name, node, elements)
      });
    }
    return "";
  }
  function isStandaloneImageParagraph(nodes) {
    return nodes.length === 1 && nodes[0].type === "image";
  }
  function renderListItemChildren(children, tight, elements, blocks, options) {
    if (children.length === 0)
      return "";
    if (!tight) {
      return `
${children.map((child) => renderBlock(child, elements, blocks, options)).join("\n")}
`;
    }
    const hasBlockChild = children.some((child) => child.type !== "paragraph");
    const body = children.map((child) => {
      if (child.type === "paragraph")
        return renderInline(child.children, elements);
      return renderBlock(child, elements, blocks, options);
    }).join("\n");
    if (!hasBlockChild)
      return body;
    if (children[children.length - 1]?.type === "paragraph")
      return `
${body}`;
    return children[0]?.type === "paragraph" ? `${body}
` : `
${body}
`;
  }
  function renderListItemChildrenFast(children, tight) {
    if (children.length === 0)
      return "";
    if (!tight) {
      return `
${children.map(renderBlockFast).join("\n")}
`;
    }
    const hasBlockChild = children.some((child) => child.type !== "paragraph");
    const body = children.map((child) => {
      if (child.type === "paragraph")
        return renderInlineFast(child.children);
      return renderBlockFast(child);
    }).join("\n");
    if (!hasBlockChild)
      return body;
    if (children[children.length - 1]?.type === "paragraph")
      return `
${body}`;
    return children[0]?.type === "paragraph" ? `${body}
` : `
${body}
`;
  }
  function renderInline(nodes, elements) {
    if (nodes.length === 0)
      return "";
    if (nodes.length === 1)
      return renderInlineNode(nodes[0], elements);
    return nodes.map((node) => renderInlineNode(node, elements)).join("");
  }
  function renderInlineNode(node, elements) {
    if (node.type === "text")
      return escapeHtml(node.value);
    if (node.type === "inlineHtml")
      return node.value;
    if (node.type === "lineBreak") {
      if (!node.hard)
        return "\n";
      const brAttrs = attrsFor("br", node, elements);
      return `<br${serializeAttrs(brAttrs)} />
`;
    }
    if (node.type === "inlineCode") {
      return wrap(resolveTag("code", node, elements), escapeHtml(node.code), attrsFor("code", node, elements));
    }
    if (node.type === "strong") {
      return wrap(resolveTag("strong", node, elements), renderInline(node.children, elements), attrsFor("strong", node, elements));
    }
    if (node.type === "emphasis") {
      return wrap(resolveTag("em", node, elements), renderInline(node.children, elements), attrsFor("em", node, elements));
    }
    if (node.type === "delete") {
      return wrap(resolveTag("del", node, elements), renderInline(node.children, elements), attrsFor("del", node, elements));
    }
    if (node.type === "image") {
      return `<img${serializeAttrs({
        src: node.src,
        alt: node.alt ?? "",
        title: node.title,
        ...attrsFor("img", node, elements)
      })} />`;
    }
    if (node.type === "link") {
      const href = node.href?.toLowerCase().trim().startsWith("javascript:") ? void 0 : node.href;
      return wrap(resolveTag("a", node, elements), renderInline(node.children, elements), {
        href,
        title: node.title,
        ...attrsFor("a", node, elements)
      });
    }
    return "";
  }
  function renderInlineFast(nodes) {
    if (nodes.length === 0)
      return "";
    if (nodes.length === 1)
      return renderInlineNodeFast(nodes[0]);
    return nodes.map(renderInlineNodeFast).join("");
  }
  function renderInlineNodeFast(node) {
    if (node.type === "text")
      return escapeHtml(node.value);
    if (node.type === "inlineHtml")
      return node.value;
    if (node.type === "lineBreak")
      return node.hard ? "<br />\n" : "\n";
    if (node.type === "inlineCode")
      return wrap("code", escapeHtml(node.code));
    if (node.type === "strong")
      return wrap("strong", renderInlineFast(node.children));
    if (node.type === "emphasis")
      return wrap("em", renderInlineFast(node.children));
    if (node.type === "delete")
      return wrap("del", renderInlineFast(node.children));
    if (node.type === "image") {
      return `<img${serializeAttrs({
        src: node.src,
        alt: node.alt ?? "",
        title: node.title
      })} />`;
    }
    if (node.type === "link") {
      const href = node.href?.toLowerCase().trim().startsWith("javascript:") ? void 0 : node.href;
      return wrap("a", renderInlineFast(node.children), {
        href,
        title: node.title
      });
    }
    return "";
  }
  function resolveTag(defaultTag, node, elements) {
    const rule = elements[defaultTag];
    if (!rule)
      return defaultTag;
    const descriptor = typeof rule === "function" ? rule(node) : rule;
    return descriptor?.tag ?? defaultTag;
  }
  function attrsFor(tag, node, elements) {
    const rule = elements[tag];
    if (!rule)
      return {};
    const descriptor = typeof rule === "function" ? rule(node) : rule;
    if (!descriptor)
      return {};
    const { tag: _t, class: _c, attr, attrs, ...rest } = descriptor;
    return { class: _c, ...attr ?? attrs, ...rest };
  }
  function tableCellAttrs(align) {
    return { align: align ?? void 0 };
  }
  function wrap(tag, content, attrs = {}) {
    return `<${tag}${serializeAttrs(attrs)}>${content}</${tag}>`;
  }
  function serializeAttrs(attrs) {
    let serialized = "";
    for (const key in attrs) {
      const value = attrs[key];
      if (value === void 0 || value === false)
        continue;
      if (isEventAttribute(key))
        continue;
      serialized += value === true ? ` ${key}` : ` ${key}="${escapeHtml(value)}"`;
    }
    return serialized;
  }
  function isEventAttribute(key) {
    return key.length > 2 && key[0].toLowerCase() === "o" && key[1].toLowerCase() === "n" && /^on[a-z]+$/i.test(key);
  }
  function isInline2(node) {
    return [
      "text",
      "emphasis",
      "strong",
      "delete",
      "lineBreak",
      "inlineCode",
      "link",
      "image",
      "inlineHtml"
    ].includes(node.type);
  }

  // ../nizel/dist/template.js
  var renderTemplate = (markdown, data, options) => {
    const filters = options.filters ?? {};
    const missing = options.missing ?? "keep";
    const rawEnabled = options.raw ?? false;
    return markdown.replace(/\{\{\{\s*([^}]+)\s*\}\}\}|\{\{\s*([^}]+)\s*\}\}/g, (match, rawExpression, escapedExpression) => {
      const isRaw = rawExpression !== void 0;
      if (isRaw && !rawEnabled)
        return match;
      const expression = (rawExpression ?? escapedExpression).trim();
      const value = evaluateExpression(expression, data, filters);
      if (value === void 0) {
        if (missing === "error") {
          throw new Error(`Missing template value: ${expression}`);
        }
        return missing === "empty" ? "" : match;
      }
      const text = textFromUnknown(value);
      return isRaw ? text : escapeHtml(text);
    });
  };
  var evaluateExpression = (expression, data, filters) => {
    const [path, ...filterParts] = expression.split("|").map((part) => part.trim());
    let value = getPath(data, path);
    for (const part of filterParts) {
      const { name, args } = parseFilter(part);
      const filter = filters[name];
      if (!filter)
        continue;
      value = filter(textFromUnknown(value), ...args);
    }
    return value;
  };
  var parseFilter = (source) => {
    const call = /^([A-Za-z0-9_-]+)\((.*)\)$/.exec(source);
    if (!call)
      return { name: source, args: [] };
    return {
      name: call[1],
      args: splitArgs(call[2]).map((arg) => {
        const trimmed = arg.trim();
        if (/^['"].*['"]$/.test(trimmed))
          return trimmed.slice(1, -1);
        if (/^-?\d+(\.\d+)?$/.test(trimmed))
          return Number(trimmed);
        return trimmed;
      })
    };
  };
  var splitArgs = (source) => {
    if (!source.trim())
      return [];
    const args = [];
    let current = "";
    let quote;
    for (const char of source) {
      if ((char === '"' || char === "'") && !quote) {
        quote = char;
      } else if (char === quote) {
        quote = void 0;
      }
      if (char === "," && !quote) {
        args.push(current);
        current = "";
        continue;
      }
      current += char;
    }
    args.push(current);
    return args;
  };

  // ../nizel/dist/use-nizel.js
  function createNizel(options = {}) {
    const presetOptions = options.preset ? resolvePreset(options.preset) : {};
    const effectiveOptions = { ...presetOptions, ...options, preset: void 0 };
    const baseResolved = resolveOptions(effectiveOptions, {});
    async function process(markdown, runtimeOptions = {}) {
      const { ast, meta, resolved } = prepareMarkdown(markdown, runtimeOptions);
      const collected = collect(ast);
      const finalHtml = renderPreparedHtml(ast, resolved);
      const output = resolved.output ?? "html";
      const result = output === "text" ? collected.text : output === "ast" ? ast : finalHtml;
      return {
        result,
        html: finalHtml,
        text: collected.text,
        ast,
        meta,
        frontmatter: meta,
        title: stringMeta(meta.title) ?? collected.headings[0]?.text,
        description: stringMeta(meta.description),
        excerpt: collected.excerpt,
        toc: resolved.toc === false ? [] : collected.headings,
        headings: collected.headings,
        links: collected.links,
        images: collected.images,
        readingTime: collected.readingTime
      };
    }
    const nizel = process;
    nizel.html = async (markdown, runtimeOptions) => {
      const { ast, resolved } = prepareMarkdown(markdown, runtimeOptions);
      return renderPreparedHtml(ast, resolved);
    };
    nizel.text = async (markdown, runtimeOptions) => {
      const { ast } = prepareMarkdown(markdown, runtimeOptions);
      return collect(ast).text;
    };
    nizel.ast = async (markdown, runtimeOptions) => {
      return prepareMarkdown(markdown, runtimeOptions).ast;
    };
    nizel.meta = async (markdown, runtimeOptions) => {
      return prepareMeta(markdown, runtimeOptions).meta;
    };
    nizel.preset = (name) => createNizel(resolvePreset(name));
    nizel.parse = async (markdown, runtimeOptions) => {
      const resolved = resolveRuntime(runtimeOptions);
      const extracted = resolved.frontmatter === false ? { markdown, frontmatter: {} } : extractFrontmatter(markdown);
      let preparedMarkdown = extracted.markdown;
      for (const plugin of resolved.plugins ?? []) {
        const next = plugin.hooks?.beforeParse?.(preparedMarkdown, resolved);
        if (next !== void 0)
          preparedMarkdown = next;
      }
      return parseMarkdown(preparedMarkdown, {
        anchors: resolved.anchors !== false,
        autolinks: resolved.autolinks,
        blocks: resolved.blocks ?? {},
        safe: resolved.safe !== false,
        slugStyle: resolved.slugStyle
      });
    };
    nizel.render = (ast, runtimeOptions) => {
      const resolved = resolveRuntime(runtimeOptions);
      return renderHtml(ast, withAutolinkElements(resolved.elements ?? {}, resolved.autolinks), resolved.blocks ?? {}, {
        unwrapStandaloneImages: resolved.unwrapStandaloneImages === true
      });
    };
    return nizel;
    function prepareMarkdown(markdown, runtimeOptions = {}) {
      const preparedMeta = prepareMeta(markdown, runtimeOptions);
      let preparedMarkdown = preparedMeta.markdown;
      for (const plugin of preparedMeta.resolved.plugins ?? []) {
        const nextMarkdown = plugin.hooks?.beforeParse?.(preparedMarkdown, preparedMeta.resolved);
        if (nextMarkdown !== void 0) {
          preparedMarkdown = nextMarkdown;
        }
      }
      let ast = parseMarkdown(preparedMarkdown, {
        anchors: preparedMeta.resolved.anchors !== false,
        autolinks: preparedMeta.resolved.autolinks,
        blocks: preparedMeta.resolved.blocks ?? {},
        safe: preparedMeta.resolved.safe !== false,
        slugStyle: preparedMeta.resolved.slugStyle
      });
      for (const plugin of preparedMeta.resolved.plugins ?? []) {
        const afterResult = plugin.hooks?.afterParse?.(ast, preparedMeta.resolved);
        if (afterResult)
          ast = afterResult;
      }
      for (const transform of preparedMeta.resolved.transforms ?? []) {
        const transformResult = transform(ast);
        if (transformResult)
          ast = transformResult;
      }
      return {
        ast,
        meta: preparedMeta.meta,
        resolved: preparedMeta.resolved
      };
    }
    function prepareMeta(markdown, runtimeOptions = {}) {
      const resolved = resolvePreparedRuntime(runtimeOptions);
      const extracted = resolved.frontmatter === false ? { markdown, frontmatter: {} } : extractFrontmatter(markdown);
      let meta = {
        ...extracted.frontmatter,
        ...resolved.meta
      };
      let data = {
        ...meta,
        ...resolved.data ?? {},
        meta,
        frontmatter: extracted.frontmatter
      };
      if (resolved.template !== false) {
        meta = renderObjectTemplates(meta, data, resolved.template);
        data = {
          ...meta,
          ...resolved.data ?? {},
          meta,
          frontmatter: meta
        };
      }
      const templated = resolved.template === false || !hasTemplateSyntax(extracted.markdown) ? extracted.markdown : renderTemplate(extracted.markdown, data, resolved.template);
      return {
        markdown: templated,
        meta,
        resolved
      };
    }
    function resolveRuntime(runtimeOptions) {
      return hasRuntimeOptions(runtimeOptions) ? resolveOptions(effectiveOptions, runtimeOptions) : baseResolved;
    }
    function resolvePreparedRuntime(runtimeOptions) {
      const resolved = resolveRuntime(runtimeOptions);
      return {
        ...resolved,
        data: { ...resolved.variables ?? {}, ...resolved.data ?? {} }
      };
    }
  }
  function renderPreparedHtml(ast, resolved) {
    const html = renderHtml(ast, withAutolinkElements(resolved.elements ?? {}, resolved.autolinks), resolved.blocks ?? {}, {
      unwrapStandaloneImages: resolved.unwrapStandaloneImages === true
    });
    let finalHtml = html;
    for (const plugin of resolved.plugins ?? []) {
      const modified = plugin.hooks?.afterRender?.(finalHtml, resolved);
      if (modified !== void 0)
        finalHtml = modified;
    }
    return finalHtml;
  }
  function renderObjectTemplates(object, data, options) {
    return Object.fromEntries(Object.entries(object).map(([key, value]) => [
      key,
      typeof value === "string" && hasTemplateSyntax(value) ? renderTemplate(value, data, options) : value
    ]));
  }
  function hasTemplateSyntax(value) {
    return value.includes("{{");
  }
  function hasRuntimeOptions(runtimeOptions) {
    return Boolean(runtimeOptions && Object.keys(runtimeOptions).length > 0);
  }
  var useNizel = createNizel;
  useNizel.preset = (name) => createNizel(resolvePreset(name));
  function stringMeta(value) {
    return typeof value === "string" ? value : void 0;
  }
  function resolvePreset(name) {
    if (name === "minimal") {
      return { frontmatter: false, template: false, toc: false, anchors: false, autolinks: false };
    }
    if (name === "blog") {
      return {
        frontmatter: true,
        toc: true,
        anchors: true,
        elements: {
          time: { class: "nizel-date" }
        }
      };
    }
    if (name === "email") {
      return {
        safe: true,
        anchors: false,
        autolinks: { enabled: true },
        elements: {
          a: { attr: { target: void 0, rel: void 0 } },
          table: { attr: { role: "presentation", cellpadding: "0", cellspacing: "0", border: "0" } }
        }
      };
    }
    if (name === "docs") {
      return {
        toc: true,
        anchors: true,
        elements: {
          h2: { class: "nizel-docs-heading" },
          code: { class: "nizel-code" }
        }
      };
    }
    return {};
  }
  function withAutolinkElements(elements, autolinks) {
    if (!autolinks || typeof autolinks !== "object" || !autolinks.target && !autolinks.rel) {
      return elements;
    }
    const existing = elements.a;
    return {
      ...elements,
      a(node) {
        const base = typeof existing === "function" ? existing(node) : existing;
        return {
          ...base,
          attrs: {
            target: autolinks.target,
            rel: autolinks.rel,
            ...base?.attrs
          }
        };
      }
    };
  }

  // ../nizel/dist/plugins/define-nizel-plugin.js
  var defineNizelPlugin = (plugin) => {
    return plugin;
  };

  // ../nizel/dist/browser.js
  function useBrowserNizel(options = {}) {
    const processor = useNizel(options);
    processor.markdownToHtml = (markdown, runtimeOptions) => processor.html(markdown, runtimeOptions);
    processor.mount = async (target, markdown, runtimeOptions) => mountMarkdown(target, markdown, runtimeOptions, processor);
    processor.htmlToMarkdown = htmlToMarkdown2;
    processor.nodeToMarkdown = nodeToMarkdown;
    processor.selectionToMarkdown = selectionToMarkdown;
    return processor;
  }
  async function mountMarkdown(target, markdown, runtimeOptions, processor = useNizel()) {
    const element = resolveMountTarget(target);
    element.innerHTML = await processor.html(markdown, runtimeOptions);
    return element;
  }
  function htmlToMarkdown2(source, options) {
    return htmlToMarkdown(sourceToHtml(source), options);
  }
  function nodeToMarkdown(source, options) {
    return htmlToMarkdown2(source, options);
  }
  function selectionToMarkdown(selection = currentSelection(), options) {
    if (!selection || selection.rangeCount === 0)
      return "";
    return htmlToMarkdown2(selection, options);
  }
  function sourceToHtml(source) {
    if (typeof source === "string")
      return source;
    if (isSelection(source))
      return serializeSelection(source);
    if (isRange(source))
      return serializeNode(source.cloneContents());
    if (isNodeList(source))
      return Array.from(source, serializeNode).join("");
    return serializeNode(source);
  }
  function serializeNode(node) {
    if (isElement(node) && typeof node.outerHTML === "string")
      return node.outerHTML;
    switch (node.nodeType) {
      case 3:
      case 4:
        return escapeHtml2(node.nodeValue ?? "");
      case 8:
        return `<!--${node.nodeValue ?? ""}-->`;
      case 9: {
        const documentNode = node;
        return documentNode.documentElement?.outerHTML ?? serializeChildren(node);
      }
      case 11:
        return serializeChildren(node);
      default:
        return "childNodes" in node ? serializeChildren(node) : "";
    }
  }
  function serializeChildren(node) {
    return Array.from(node.childNodes, serializeNode).join("");
  }
  function serializeSelection(selection) {
    const fragments = [];
    for (let index = 0; index < selection.rangeCount; index += 1) {
      fragments.push(serializeNode(selection.getRangeAt(index).cloneContents()));
    }
    return fragments.join("");
  }
  function resolveMountTarget(target) {
    if (typeof target !== "string")
      return target;
    if (typeof document === "undefined") {
      throw new Error("nizel/browser mountMarkdown() needs a browser document when target is a selector.");
    }
    const element = document.querySelector(target);
    if (!element)
      throw new Error(`nizel/browser could not find mount target: ${target}`);
    return element;
  }
  function currentSelection() {
    return typeof globalThis.getSelection === "function" ? globalThis.getSelection() : null;
  }
  function isSelection(value) {
    return "rangeCount" in value && "getRangeAt" in value;
  }
  function isRange(value) {
    return "cloneContents" in value && "startContainer" in value && "endContainer" in value;
  }
  function isNodeList(value) {
    return "length" in value && !("nodeType" in value);
  }
  function isElement(value) {
    return value.nodeType === 1 && "outerHTML" in value;
  }
  function escapeHtml2(value) {
    return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  // ../plugin-abbr/dist/index.js
  var abbrPlugin = (options = {}) => {
    let definitions = options.definitions ?? {};
    return {
      name: "abbr",
      hooks: {
        beforeParse(markdown) {
          const result = extractAbbreviations(markdown);
          definitions = { ...definitions, ...result.definitions };
          return result.markdown;
        },
        afterParse(ast) {
          return replaceAbbreviations(ast, definitions);
        }
      },
      htmlToMarkdown: abbrToMarkdown()
    };
  };
  var abbrToMarkdown = () => {
    const seen = /* @__PURE__ */ new Set();
    return (node, ctx) => {
      if (node.type !== "element" || node.tag !== "abbr")
        return void 0;
      const term = ctx.text(node).trim();
      const title = node.attrs.title;
      if (title !== void 0 && term && !seen.has(term)) {
        seen.add(term);
        ctx.epilogue(`*[${term}]: ${title}`);
      }
      return term;
    };
  };
  var extractAbbreviations = (markdown) => {
    const definitions = {};
    const lines = markdown.split("\n").filter((line) => {
      const match = /^\*\[([^\]]+)\]:\s*(.+)$/.exec(line);
      if (!match)
        return true;
      definitions[match[1]] = match[2];
      return false;
    });
    return { markdown: lines.join("\n"), definitions };
  };
  var replaceAbbreviations = (ast, definitions) => ({
    ...ast,
    children: ast.children.map((node) => transformBlock(node, definitions))
  });
  var transformBlock = (node, definitions) => {
    if (node.type === "paragraph" || node.type === "heading")
      return { ...node, children: transformInline(node.children, definitions) };
    if (node.type === "blockquote")
      return { ...node, children: node.children.map((child) => transformBlock(child, definitions)) };
    if (node.type === "list")
      return { ...node, children: node.children.map((item) => ({ ...item, children: item.children.map((child) => transformBlock(child, definitions)) })) };
    if (node.type === "customBlock")
      return { ...node, children: node.children?.map((child) => transformBlock(child, definitions)) };
    return node;
  };
  var transformInline = (nodes, definitions) => {
    return nodes.flatMap((node) => {
      if (node.type === "text")
        return replaceText(node.value, definitions);
      if ("children" in node)
        return [{ ...node, children: transformInline(node.children, definitions) }];
      return [node];
    });
  };
  var replaceText = (value, definitions) => {
    const terms = Object.keys(definitions).sort((a, b2) => b2.length - a.length);
    if (terms.length === 0)
      return [{ type: "text", value }];
    const pattern = new RegExp(`\\b(${terms.map(escapeRegExp).join("|")})\\b`, "g");
    const nodes = [];
    let lastIndex = 0;
    let match;
    while (match = pattern.exec(value)) {
      if (match.index > lastIndex)
        nodes.push({ type: "text", value: value.slice(lastIndex, match.index) });
      nodes.push({ type: "inlineHtml", value: `<abbr title="${escapeHtml3(definitions[match[1]])}">${escapeHtml3(match[1])}</abbr>` });
      lastIndex = pattern.lastIndex;
    }
    if (lastIndex < value.length)
      nodes.push({ type: "text", value: value.slice(lastIndex) });
    return nodes;
  };
  var escapeRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  var escapeHtml3 = (value) => value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

  // ../plugin-alert/dist/index.js
  var ALERT_TYPES = ["note", "tip", "important", "warning", "caution"];
  var alertPlugin = (options = {}) => {
    const blocks = Object.fromEntries(ALERT_TYPES.map((alertType) => [alertType, createAlertBlock(alertType, options)]));
    return {
      name: "alert",
      blocks,
      hooks: {
        beforeParse: transformGitHubAlerts
      },
      htmlToMarkdown: alertToMarkdown(options)
    };
  };
  var alertToMarkdown = (options = {}) => {
    const rootClass = options.className ?? "alert";
    return (node, ctx) => {
      if (node.type !== "element" || node.tag !== "div")
        return void 0;
      const type = node.attrs["data-alert"];
      if (!type)
        return void 0;
      const titleEl = findHtmlElement(node, (el) => el.tag === "p" && hasHtmlClass(el, `${rootClass}__title`));
      const contentEl = findHtmlElement(node, (el) => hasHtmlClass(el, `${rootClass}__content`));
      const title = titleEl ? ctx.text(titleEl).trim() : "";
      const body = contentEl ? ctx.block(contentEl) : "";
      return `${title ? `::${type} ${title}` : `::${type}`}
${body}
::`;
    };
  };
  var transformGitHubAlerts = (markdown) => {
    const lines = markdown.split("\n");
    const result = [];
    let index = 0;
    while (index < lines.length) {
      const opener = /^ {0,3}> ?\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$/i.exec(lines[index]);
      if (!opener) {
        result.push(lines[index]);
        index += 1;
        continue;
      }
      const alertType = opener[1].toLowerCase();
      const content = [];
      index += 1;
      while (index < lines.length) {
        const quoteLine = /^ {0,3}> ?(.*)$/.exec(lines[index]);
        if (!quoteLine)
          break;
        content.push(quoteLine[1]);
        index += 1;
      }
      result.push(`::${alertType} ${alertTitle(alertType)}`);
      result.push(...trimAlertContent(content));
      result.push("::");
    }
    return result.join("\n");
  };
  var createAlertBlock = (alertType, options) => {
    return {
      name: alertType,
      parse({ args, props }) {
        const title = props.title ?? args[0] ?? "";
        return { alertType, title: String(title) };
      },
      formats: {
        html(node, ctx) {
          if (node.type !== "customBlock" || !isAlertValue(node.value))
            return "";
          return renderAlert(node.value, node.children ?? [], ctx, options);
        }
      }
    };
  };
  var renderAlert = (value, children, ctx, options) => {
    const rootClass = options.className ?? "alert";
    const titleHtml = value.title ? `<p class="${rootClass}__title">${ctx.escape(value.title)}</p>` : "";
    const contentHtml = ctx.render(children);
    const escapedType = ctx.escape(value.alertType);
    return `<div class="${ctx.escape(rootClass)} ${ctx.escape(rootClass)}--${escapedType}" data-alert="${escapedType}">${titleHtml}<div class="${ctx.escape(rootClass)}__content">${contentHtml}</div></div>`;
  };
  var trimAlertContent = (lines) => {
    let start = 0;
    let end = lines.length;
    while (start < end && !lines[start].trim())
      start += 1;
    while (end > start && !lines[end - 1].trim())
      end -= 1;
    return lines.slice(start, end);
  };
  var alertTitle = (alertType) => {
    return alertType.charAt(0).toUpperCase() + alertType.slice(1);
  };
  var isAlertValue = (value) => {
    if (!value || typeof value !== "object")
      return false;
    const candidate = value;
    return typeof candidate.title === "string" && ALERT_TYPES.includes(candidate.alertType);
  };

  // ../plugin-autolink/dist/index.js
  var resolveAutolinkPluginOptions = (options = {}) => {
    return {
      enabled: options.enabled ?? true,
      target: options.target,
      rel: options.rel
    };
  };
  var autolinkPlugin = (options = {}) => {
    return defineNizelPlugin({
      name: "autolink",
      options: {
        autolinks: resolveAutolinkPluginOptions(options)
      },
      htmlToMarkdown: autolinkToMarkdown()
    });
  };
  var autolinkToMarkdown = () => (node, ctx) => {
    if (node.type !== "element" || node.tag !== "a")
      return void 0;
    const href = node.attrs.href;
    if (!href)
      return void 0;
    const extras = Object.keys(node.attrs).filter((key) => key !== "href" && key !== "target" && key !== "rel");
    if (extras.length > 0)
      return void 0;
    return ctx.text(node).trim() === href ? href : void 0;
  };

  // ../plugin-code-copy/dist/index.js
  var codeCopyPlugin = (options = {}) => {
    const copiedLabel = options.copiedLabel ?? "Copied";
    const label = options.label ?? "Copy";
    const mode = options.mode ?? "inline";
    return defineNizelPlugin({
      name: "code-copy",
      blocks: {
        "code-copy": {
          name: "code-copy",
          formats: {
            html(node, ctx) {
              if (node.type !== "customBlock")
                return "";
              return renderCodeCopyBlock(node, ctx, { copiedLabel, label, mode });
            }
          }
        }
      },
      hooks: {
        afterParse: wrapCodeBlocks
      },
      htmlToMarkdown: codeCopyToMarkdown()
    });
  };
  var codeCopyToMarkdown = () => (node, ctx) => {
    if (node.type !== "element" || node.tag !== "figure" || node.attrs["data-nizel-code-copy"] === void 0)
      return void 0;
    const source = findHtmlDescendant(node, (el) => el.tag === "textarea" && el.attrs["data-nizel-copy-source"] !== void 0);
    if (!source) {
      const body = htmlChildElements(node).filter((el) => !["figcaption", "textarea", "button"].includes(el.tag));
      return ctx.block(htmlRoot(body));
    }
    const code = ctx.text(source).replace(/\n$/, "");
    const pre = findHtmlDescendant(node, (el) => el.tag === "pre");
    const codeEl = pre ? findHtmlElement(pre, (el) => el.tag === "code") : void 0;
    const codeClass = codeEl?.attrs.class ?? "";
    const langClass = codeClass.match(/\blanguage-([A-Za-z0-9_-]+)/)?.[1];
    const isMermaid = findHtmlDescendant(node, (el) => el.tag === "div" && el.attrs.class === "mermaid") !== void 0;
    const lang = langClass ?? pre?.attrs["data-language"] ?? (isMermaid ? "mermaid" : "");
    const fence = fenceFor(code);
    return `${fence}${lang}
${code}
${fence}`;
  };
  var fenceFor = (code) => {
    const longest = Math.max(0, ...(code.match(/`+/g) ?? []).map((run) => run.length));
    return "`".repeat(Math.max(3, longest + 1));
  };
  var wrapCodeBlocks = (ast) => ({
    ...ast,
    children: ast.children.map(wrapCodeBlock)
  });
  var wrapCodeBlock = (node) => {
    if (node.type === "code")
      return createCodeCopyNode(node, node);
    if (node.type === "customBlock") {
      if (node.name === "code-copy")
        return node;
      const source = sourceFromCustomBlock(node);
      if (source)
        return createCodeCopyNode(source, node);
      return node.children ? { ...node, children: node.children.map(wrapCodeBlock) } : node;
    }
    if (node.type === "blockquote") {
      return { ...node, children: node.children.map(wrapCodeBlock) };
    }
    if (node.type === "list") {
      return {
        ...node,
        children: node.children.map((item) => ({
          ...item,
          children: item.children.map(wrapCodeBlock)
        }))
      };
    }
    return node;
  };
  var createCodeCopyNode = (value, child) => ({
    type: "customBlock",
    name: "code-copy",
    value,
    children: [child]
  });
  var sourceFromCustomBlock = (node) => {
    if (node.name !== "diagram")
      return void 0;
    const value = node.value;
    return typeof value?.code === "string" ? {
      code: value.code,
      filename: value.filename,
      lang: value.lang
    } : void 0;
  };
  var renderCodeCopyBlock = (node, ctx, options) => {
    const value = node.value;
    const filename = value?.filename ? `<figcaption>${ctx.escape(value.filename)}</figcaption>` : "";
    const source = typeof value?.code === "string" ? `<textarea class="nizel-code-copy__source" data-nizel-copy-source hidden readonly tabindex="-1" aria-hidden="true" style="display: none">${ctx.escape(value.code)}</textarea>` : "";
    const body = ctx.render(node.children ?? []);
    const onclick = options.mode === "inline" ? ` onclick="${ctx.escape(createInlineCopyHandler(options.copiedLabel))}"` : "";
    return `<figure class="nizel-code-copy" data-nizel-code-copy>${filename}${source}<button type="button" class="nizel-code-copy__button" data-nizel-copy-button${onclick}>${ctx.escape(options.label)}</button>${body}</figure>`;
  };
  var createInlineCopyHandler = (copiedLabel) => {
    const label = jsString(copiedLabel);
    return `var b=this,f=b.closest('[data-nizel-code-copy]'),s=f?f.querySelector('[data-nizel-copy-source]'):null,v=s?s.value:'',p=b.textContent,d=function(){b.textContent='${label}';setTimeout(function(){b.textContent=p;},1200)},c=function(){var t=document.createElement('textarea');t.value=v;t.setAttribute('readonly','');t.style.position='fixed';t.style.opacity='0';document.body.appendChild(t);t.select();document.execCommand('copy');document.body.removeChild(t);d()};if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(v).then(d,c)}else{c()}`;
  };
  var jsString = (value) => value.replace(/\\/g, "\\\\").replace(/'/g, "\\'").replace(/\r/g, "\\r").replace(/\n/g, "\\n").replace(/\u2028/g, "\\u2028").replace(/\u2029/g, "\\u2029");

  // ../plugin-citations/dist/index.js
  var citationsPlugin = (options = {}) => {
    let citations = {};
    return {
      name: "citations",
      blocks: {
        bibliography: bibliographyBlock(options)
      },
      hooks: {
        beforeParse(markdown) {
          const result = extractCitations(markdown);
          citations = result.citations;
          return result.markdown;
        },
        afterParse(ast) {
          return appendBibliography(replaceCitationRefs(ast, citations), citations);
        }
      },
      htmlToMarkdown: citationsToMarkdown(options)
    };
  };
  var citationsToMarkdown = (options = {}) => {
    const className = options.className ?? "citations";
    return (node, ctx) => {
      if (node.type !== "element")
        return void 0;
      if (node.tag === "a" && hasHtmlClass(node, "citation")) {
        const match = /^#cite-(.+)$/.exec(node.attrs.href ?? "");
        return match ? `[@${match[1]}]` : void 0;
      }
      if (node.tag === "section" && hasHtmlClass(node, className)) {
        const list = findHtmlElement(node, (el) => el.tag === "ol");
        const items = list ? htmlChildElements(list).filter((el) => el.tag === "li") : [];
        return items.map((li) => {
          const id = /^cite-(.+)$/.exec(li.attrs.id ?? "")?.[1] ?? "";
          return `[@${id}]: ${ctx.block(htmlRoot(li.children)).trim()}`;
        }).join("\n");
      }
      return void 0;
    };
  };
  var extractCitations = (markdown) => {
    const citations = {};
    const lines = markdown.split("\n").filter((line) => {
      const match = /^\[@([A-Za-z0-9_-]+)\]:\s*(.+)$/.exec(line);
      if (!match)
        return true;
      citations[match[1]] = match[2];
      return false;
    });
    return { markdown: lines.join("\n"), citations };
  };
  var replaceCitationRefs = (ast, citations) => ({
    ...ast,
    children: ast.children.map((node) => transformBlock2(node, citations))
  });
  var appendBibliography = (ast, citations) => {
    const entries = Object.entries(citations).map(([id, text]) => `${id}	${text}`);
    if (entries.length === 0)
      return ast;
    return {
      ...ast,
      children: [...ast.children, { type: "customBlock", name: "bibliography", value: { entries: Object.entries(citations).map(([id, text]) => ({ id, text })) }, children: [] }]
    };
  };
  var bibliographyBlock = (options) => ({
    name: "bibliography",
    parse({ content }) {
      return { entries: content.split("\n").filter(Boolean).map((line) => {
        const [id, ...text] = line.split("	");
        return { id, text: text.join("	") };
      }) };
    },
    formats: {
      html(node, ctx) {
        if (node.type !== "customBlock")
          return "";
        const entries = node.value?.entries ?? [];
        const items = entries.map((entry) => `<li id="cite-${ctx.escape(entry.id)}">${ctx.escape(entry.text)}</li>`).join("");
        return `<section class="${ctx.escape(options.className ?? "citations")}"><ol>${items}</ol></section>`;
      }
    }
  });
  var transformBlock2 = (node, citations) => {
    if (node.type === "paragraph" || node.type === "heading")
      return { ...node, children: transformInline2(node.children, citations) };
    if (node.type === "blockquote")
      return { ...node, children: node.children.map((child) => transformBlock2(child, citations)) };
    if (node.type === "list")
      return { ...node, children: node.children.map((item) => ({ ...item, children: item.children.map((child) => transformBlock2(child, citations)) })) };
    return node;
  };
  var transformInline2 = (nodes, citations) => nodes.flatMap((node) => {
    if (node.type === "text")
      return replaceText2(node.value, citations);
    if ("children" in node)
      return [{ ...node, children: transformInline2(node.children, citations) }];
    return [node];
  });
  var replaceText2 = (value, citations) => {
    const nodes = [];
    const pattern = /\[@([A-Za-z0-9_-]+)\]/g;
    let lastIndex = 0;
    let match;
    while (match = pattern.exec(value)) {
      if (match.index > lastIndex)
        nodes.push({ type: "text", value: value.slice(lastIndex, match.index) });
      nodes.push(citations[match[1]] ? { type: "inlineHtml", value: `<a class="citation" href="#cite-${escapeHtml4(match[1])}">[${escapeHtml4(match[1])}]</a>` } : { type: "text", value: match[0] });
      lastIndex = pattern.lastIndex;
    }
    if (lastIndex < value.length)
      nodes.push({ type: "text", value: value.slice(lastIndex) });
    return nodes;
  };
  var escapeHtml4 = (value) => value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

  // ../plugin-deflist/dist/index.js
  var deflistPlugin = (options = {}) => {
    return {
      name: "deflist",
      blocks: {
        deflist: {
          name: "deflist",
          parse({ content }) {
            const parsed = readDefinitionList(content.split("\n"), 0);
            return { entries: parsed?.entries ?? [] };
          },
          formats: {
            html(node) {
              if (node.type !== "customBlock" || !isDeflistValue(node.value))
                return "";
              return renderDefinitionList(node.value.entries, options);
            }
          }
        }
      },
      hooks: {
        beforeParse(markdown) {
          return transformDefinitionLists(markdown, options);
        }
      },
      htmlToMarkdown: deflistToMarkdown(options)
    };
  };
  var deflistToMarkdown = (options = {}) => (node, ctx) => {
    if (node.type !== "element" || node.tag !== "dl")
      return void 0;
    if (options.className) {
      if (node.attrs.class !== options.className)
        return void 0;
    } else if (node.attrs.class !== void 0) {
      return void 0;
    }
    const lines = [];
    for (const el of htmlChildElements(node)) {
      if (el.tag === "dt")
        lines.push(ctx.inline(el));
      else if (el.tag === "dd")
        lines.push(`: ${ctx.inline(el)}`);
    }
    return lines.join("\n");
  };
  var transformDefinitionLists = (markdown, _options = {}) => {
    const lines = markdown.split("\n");
    const result = [];
    let index = 0;
    while (index < lines.length) {
      const parsed = readDefinitionList(lines, index);
      if (!parsed) {
        result.push(lines[index]);
        index += 1;
        continue;
      }
      result.push(renderDefinitionBlockSource(parsed.lines));
      index = parsed.nextIndex;
    }
    return result.join("\n");
  };
  var readDefinitionList = (lines, startIndex) => {
    if (!isDefinitionTermStart(lines, startIndex))
      return null;
    const entries = [];
    const sourceLines = [];
    let index = startIndex;
    while (index < lines.length && isDefinitionTermStart(lines, index)) {
      const term = lines[index].trim();
      const definitions = [];
      sourceLines.push(lines[index]);
      index += 1;
      while (index < lines.length && isDefinitionLine(lines[index])) {
        definitions.push(lines[index].trimStart().slice(2).trim());
        sourceLines.push(lines[index]);
        index += 1;
      }
      entries.push({ term, definitions });
      const next = nextNonBlankLine2(lines, index);
      if (next === -1 || !isDefinitionTermStart(lines, next))
        break;
      while (index < next) {
        sourceLines.push(lines[index]);
        index += 1;
      }
      index = next;
    }
    return { entries, lines: sourceLines, nextIndex: index };
  };
  var renderDefinitionList = (entries, options = {}) => {
    const classAttribute = options.className ? ` class="${escapeHtml5(options.className)}"` : "";
    const body = entries.map((entry) => {
      const definitions = entry.definitions.map((definition) => `  <dd>${escapeHtml5(definition)}</dd>`).join("\n");
      return `  <dt>${escapeHtml5(entry.term)}</dt>
${definitions}`;
    }).join("\n");
    return `<dl${classAttribute}>
${body}
</dl>`;
  };
  var isDefinitionTermStart = (lines, index) => {
    return Boolean(lines[index]?.trim() && !isDefinitionLine(lines[index]) && isDefinitionLine(lines[index + 1] ?? ""));
  };
  var isDefinitionLine = (line) => line.trimStart().startsWith(": ");
  var nextNonBlankLine2 = (lines, startIndex) => {
    let index = startIndex;
    while (index < lines.length && !lines[index].trim())
      index += 1;
    return index < lines.length ? index : -1;
  };
  var escapeHtml5 = (value) => {
    return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  };
  var renderDefinitionBlockSource = (lines) => {
    return ["::deflist", ...lines, "::"].join("\n");
  };
  var isDeflistValue = (value) => {
    if (!value || typeof value !== "object")
      return false;
    const candidate = value;
    return Array.isArray(candidate.entries);
  };

  // ../plugin-details/dist/index.js
  var detailsPlugin = (options = {}) => ({
    name: "details",
    blocks: {
      details: detailsBlock(options)
    },
    hooks: {
      beforeParse: transformDetails
    },
    htmlToMarkdown: detailsToMarkdown(options)
  });
  var detailsToMarkdown = (options = {}) => {
    const className = options.className ?? "details";
    return (node, ctx) => {
      if (node.type !== "element" || node.tag !== "details" || node.attrs.class !== className)
        return void 0;
      const summaryEl = findHtmlElement(node, (el) => el.tag === "summary");
      const summary = summaryEl ? ctx.text(summaryEl).trim() : "Details";
      const body = ctx.block(htmlRoot(htmlChildElements(node).filter((el) => el.tag !== "summary"))).trim();
      return body ? `::details ${summary}
${body}
::` : `::details ${summary}
::`;
    };
  };
  var transformDetails = (markdown) => {
    return markdown.replace(/^:::details\s*(.*?)\s*$/gm, (_match, summary) => `::details ${summary || "Details"}`).replace(/^:::\s*$/gm, "::");
  };
  var detailsBlock = (options) => ({
    name: "details",
    parse({ args }) {
      return { summary: args.join(" ") || "Details" };
    },
    formats: {
      html(node, ctx) {
        if (node.type !== "customBlock")
          return "";
        const summary = node.value?.summary ?? "Details";
        return `<details class="${ctx.escape(options.className ?? "details")}"><summary>${ctx.escape(summary)}</summary>${ctx.render(node.children ?? [])}</details>`;
      }
    }
  });

  // ../plugin-diagrams/dist/index.js
  var diagramsPlugin = (options = {}) => {
    return {
      name: "diagrams",
      blocks: {
        diagram: diagramBlock(options)
      },
      hooks: {
        afterParse(ast) {
          return transformDiagramCodes(ast, options);
        }
      },
      htmlToMarkdown: diagramsToMarkdown(options)
    };
  };
  var diagramsToMarkdown = (options = {}) => {
    const className = options.className ?? "mermaid";
    return (node, ctx) => {
      if (node.type !== "element" || node.tag !== "div" || node.attrs.class !== className)
        return void 0;
      const code = ctx.text(node).trim();
      return `\`\`\`mermaid
${code}
\`\`\``;
    };
  };
  var transformDiagramCodes = (ast, options = {}) => ({
    ...ast,
    children: ast.children.map((node) => transformBlock3(node, options))
  });
  var transformBlock3 = (node, options) => {
    if (options.mermaid !== false && node.type === "code" && node.lang === "mermaid") {
      return {
        type: "customBlock",
        name: "diagram",
        value: {
          code: node.code,
          lang: "mermaid"
        },
        children: []
      };
    }
    if (node.type === "blockquote") {
      return { ...node, children: node.children.map((child) => transformBlock3(child, options)) };
    }
    if (node.type === "list") {
      return {
        ...node,
        children: node.children.map((item) => ({
          ...item,
          children: item.children.map((child) => transformBlock3(child, options))
        }))
      };
    }
    if (node.type === "customBlock" && node.children) {
      return { ...node, children: node.children.map((child) => transformBlock3(child, options)) };
    }
    return node;
  };
  var diagramBlock = (options) => ({
    name: "diagram",
    formats: {
      html(node, ctx) {
        if (node.type !== "customBlock")
          return "";
        const value = node.value;
        if (value?.lang !== "mermaid" || typeof value.code !== "string")
          return "";
        return `<div class="${ctx.escape(options.className ?? "mermaid")}">${ctx.escape(value.code.trimEnd())}</div>`;
      }
    }
  });

  // ../plugin-emoji/dist/index.js
  var DEFAULT_EMOJI_MAP = {
    smile: "\u{1F604}",
    laughing: "\u{1F606}",
    blush: "\u{1F60A}",
    heart: "\u2764\uFE0F",
    thumbsup: "\u{1F44D}",
    thumbsdown: "\u{1F44E}",
    fire: "\u{1F525}",
    rocket: "\u{1F680}",
    check: "\u2705",
    white_check_mark: "\u2705",
    x: "\u274C",
    warning: "\u26A0\uFE0F",
    star: "\u2B50",
    bulb: "\u{1F4A1}",
    memo: "\u{1F4DD}",
    link: "\u{1F517}",
    eyes: "\u{1F440}",
    thinking: "\u{1F914}",
    tada: "\u{1F389}",
    bug: "\u{1F41B}",
    construction: "\u{1F6A7}",
    wrench: "\u{1F527}"
  };
  var EMOJI_PATTERN = /:([a-z0-9_+-]+):/g;
  var emojiPlugin = (options = {}) => {
    const emojiMap = options.emojiMap ? { ...DEFAULT_EMOJI_MAP, ...options.emojiMap } : DEFAULT_EMOJI_MAP;
    return defineNizelPlugin({
      name: "emoji",
      hooks: {
        beforeParse(markdown) {
          return replaceEmojisOutsideCode(markdown, emojiMap);
        }
      }
    });
  };
  var replaceEmojisOutsideCode = (markdown, emojiMap) => {
    const segments = [];
    let remaining = markdown;
    while (remaining.length > 0) {
      const fenceMatch = /^( {0,3})(`{3,}|~{3,})[ \t]*.*$/m.exec(remaining);
      if (!fenceMatch) {
        segments.push(replaceEmojisProtectInlineCode(remaining, emojiMap));
        break;
      }
      const fenceStart = fenceMatch.index;
      const fenceMarker = fenceMatch[2];
      const fenceChar = fenceMarker[0];
      const fenceLength = fenceMarker.length;
      const closePattern = new RegExp(`^ {0,3}\\${fenceChar}{${fenceLength},}\\s*$`, "m");
      const afterOpen = remaining.slice(fenceStart + fenceMatch[0].length);
      const closeMatch = closePattern.exec(afterOpen);
      const fenceEnd = closeMatch ? fenceStart + fenceMatch[0].length + closeMatch.index + closeMatch[0].length : remaining.length;
      segments.push(replaceEmojisProtectInlineCode(remaining.slice(0, fenceStart), emojiMap));
      segments.push(remaining.slice(fenceStart, fenceEnd));
      remaining = remaining.slice(fenceEnd);
    }
    return segments.join("");
  };
  var replaceEmojisProtectInlineCode = (text, emojiMap) => {
    const result = [];
    let remaining = text;
    while (remaining.length > 0) {
      const codeStart = remaining.indexOf("`");
      if (codeStart === -1) {
        result.push(replaceEmojis(remaining, emojiMap));
        break;
      }
      if (codeStart > 0)
        result.push(replaceEmojis(remaining.slice(0, codeStart), emojiMap));
      const codeEnd = remaining.indexOf("`", codeStart + 1);
      if (codeEnd === -1) {
        result.push(remaining.slice(codeStart));
        break;
      }
      result.push(remaining.slice(codeStart, codeEnd + 1));
      remaining = remaining.slice(codeEnd + 1);
    }
    return result.join("");
  };
  var replaceEmojis = (text, emojiMap) => {
    return text.replace(EMOJI_PATTERN, (match, name) => emojiMap[name] ?? match);
  };

  // ../plugin-footnotes/dist/index.js
  var footnotesPlugin = (options = {}) => {
    return {
      name: "footnotes",
      blocks: {
        footnotes: footnotesBlock(options)
      },
      hooks: {
        beforeParse: transformFootnotes,
        afterParse: transformFootnoteRefs
      },
      htmlToMarkdown: footnotesToMarkdown(options)
    };
  };
  var footnotesToMarkdown = (options = {}) => {
    const className = options.className ?? "footnotes";
    return (node, ctx) => {
      if (node.type !== "element")
        return void 0;
      if (node.tag === "sup") {
        const anchor = findHtmlElement(node, (el) => el.tag === "a" && hasHtmlClass(el, "footnote-ref"));
        const match = anchor ? /^#fn-(.+)$/.exec(anchor.attrs.href ?? "") : void 0;
        return match ? `[^${match[1]}]` : void 0;
      }
      if (node.tag === "section" && hasHtmlClass(node, className)) {
        const list = findHtmlElement(node, (el) => el.tag === "ol");
        const items = list ? htmlChildElements(list).filter((el) => el.tag === "li") : [];
        return items.map((li) => {
          const id = /^fn-(.+)$/.exec(li.attrs.id ?? "")?.[1] ?? "";
          const body = ctx.block(htmlRoot(stripBackrefs(li.children, className))).trim();
          return `[^${id}]: ${body}`;
        }).join("\n");
      }
      return void 0;
    };
  };
  var stripBackrefs = (nodes, className) => {
    const result = [];
    for (const node of nodes) {
      if (node.type === "element") {
        if (hasHtmlClass(node, `${className}__backref`))
          continue;
        result.push({ ...node, children: stripBackrefs(node.children, className) });
      } else {
        result.push(node);
      }
    }
    return result;
  };
  var transformFootnotes = (markdown) => {
    const lines = markdown.split("\n");
    const body = [];
    const footnotes = [];
    for (const line of lines) {
      const definition = /^\[\^([^\]]+)\]:\s*(.*)$/.exec(line);
      if (!definition) {
        body.push(line);
        continue;
      }
      footnotes.push({ id: definition[1], content: definition[2] });
    }
    const orderedIds = new Map(footnotes.map((entry, index) => [entry.id, index + 1]));
    const transformedBody = body.join("\n").replace(/\[\^([^\]]+)\]/g, (match, id) => {
      const index = orderedIds.get(id);
      return index === void 0 ? match : `{{nizel-footnote-ref:${id}:${index}}}`;
    });
    if (footnotes.length === 0)
      return transformedBody;
    return [
      transformedBody,
      "",
      "::footnotes",
      ...footnotes.map((entry, index) => `${index + 1}	${entry.id}	${entry.content}`),
      "::"
    ].join("\n");
  };
  var transformFootnoteRefs = (ast) => {
    return { ...ast, children: ast.children.map(transformBlock4) };
  };
  var footnotesBlock = (options) => ({
    name: "footnotes",
    parse({ content }) {
      return {
        entries: content.split("\n").filter(Boolean).map((line) => {
          const [index, id, ...contentParts] = line.split("	");
          return { index: Number(index), id, content: contentParts.join("	") };
        })
      };
    },
    formats: {
      html(node, ctx) {
        if (node.type !== "customBlock")
          return "";
        const entries = node.value?.entries ?? [];
        const className = options.className ?? "footnotes";
        const items = entries.map((entry) => `<li id="fn-${slug(entry.id)}">${ctx.escape(entry.content)} <a href="#fnref-${slug(entry.id)}" class="${className}__backref">\u21A9</a></li>`).join("");
        return `<section class="${ctx.escape(className)}"><ol>${items}</ol></section>`;
      }
    }
  });
  var transformBlock4 = (node) => {
    if (node.type === "paragraph" || node.type === "heading") {
      return { ...node, children: transformInlineNodes(node.children) };
    }
    if (node.type === "blockquote")
      return { ...node, children: node.children.map(transformBlock4) };
    if (node.type === "list") {
      return { ...node, children: node.children.map((item) => ({ ...item, children: item.children.map(transformBlock4) })) };
    }
    if (node.type === "table") {
      return {
        ...node,
        children: node.children.map((row) => ({
          ...row,
          children: row.children.map((cell) => ({ ...cell, children: transformInlineNodes(cell.children) }))
        }))
      };
    }
    if (node.type === "customBlock")
      return { ...node, children: node.children?.map(transformBlock4) };
    return node;
  };
  var transformInlineNodes = (nodes) => {
    const transformed = [];
    for (const node of nodes) {
      if (node.type === "text")
        transformed.push(...transformText(node.value));
      else if ("children" in node)
        transformed.push({ ...node, children: transformInlineNodes(node.children) });
      else
        transformed.push(node);
    }
    return transformed;
  };
  var transformText = (value) => {
    const nodes = [];
    const pattern = /\{\{nizel-footnote-ref:([^:}]+):([0-9]+)\}\}/g;
    let lastIndex = 0;
    let match;
    while (match = pattern.exec(value)) {
      if (match.index > lastIndex)
        nodes.push({ type: "text", value: value.slice(lastIndex, match.index) });
      const id = slug(match[1]);
      nodes.push({ type: "inlineHtml", value: `<sup id="fnref-${id}"><a href="#fn-${id}" class="footnote-ref">${escapeHtml6(match[2])}</a></sup>` });
      lastIndex = pattern.lastIndex;
    }
    if (lastIndex < value.length)
      nodes.push({ type: "text", value: value.slice(lastIndex) });
    return nodes;
  };
  var slug = (value) => value.toLowerCase().replace(/[^a-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "");
  var escapeHtml6 = (value) => value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

  // ../plugin-frontmatter-ui/dist/index.js
  var frontmatterUiPlugin = (options = {}) => ({
    name: "frontmatter-ui",
    blocks: {
      frontmatter: frontmatterBlock(options)
    }
  });
  var renderFrontmatterMeta = (meta, options = {}) => {
    const rows = Object.entries(meta).map(([key, value]) => `<dt>${escapeHtml7(key)}</dt><dd>${escapeHtml7(formatValue(value))}</dd>`).join("");
    return `<dl class="${escapeHtml7(options.className ?? "frontmatter")}">${rows}</dl>`;
  };
  var frontmatterBlock = (options) => ({
    name: "frontmatter",
    parse({ content, props }) {
      const contentMeta = Object.fromEntries(content.split("\n").filter(Boolean).map((line) => {
        const [key, ...value] = line.split(":");
        return [key.trim(), value.join(":").trim()];
      }));
      const meta = { ...props, ...contentMeta };
      return { meta };
    },
    formats: {
      html(node) {
        if (node.type !== "customBlock")
          return "";
        return renderFrontmatterMeta(node.value?.meta ?? {}, options);
      }
    }
  });
  var formatValue = (value) => Array.isArray(value) ? value.join(", ") : String(value);
  var escapeHtml7 = (value) => value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

  // ../plugin-task-list/dist/index.js
  var taskListPlugin = (options = {}) => {
    const mode = options.mode ?? "view";
    return {
      name: "task-list",
      hooks: {
        afterParse(ast) {
          return transformTaskLists(ast, mode);
        }
      },
      htmlToMarkdown: taskListToMarkdown()
    };
  };
  var CHECKBOX_ATTR = "data-nizel-task-checkbox";
  var isCheckbox = (node) => node.type === "element" && node.tag === "input" && node.attrs?.[CHECKBOX_ATTR] !== void 0;
  var taskListToMarkdown = () => (node, ctx) => {
    if (node.type !== "element" || node.tag !== "ul" && node.tag !== "ol")
      return void 0;
    const items = htmlChildElements(node).filter((el) => el.tag === "li");
    if (!items.some((item) => findHtmlDescendant(item, isCheckbox)))
      return void 0;
    const ordered = node.tag === "ol";
    const start = Number(node.attrs.start ?? 1);
    return items.map((item, index) => {
      const checkbox = findHtmlDescendant(item, isCheckbox);
      const body = ctx.block(htmlRoot(cleanTaskChildren(item.children))).trim();
      const baseMarker = ordered ? `${start + index}. ` : "- ";
      const marker = checkbox ? `${baseMarker}${checkbox.attrs.checked !== void 0 ? "[x] " : "[ ] "}` : baseMarker;
      return ctx.indent(`${marker}${body}`, marker.length);
    }).join("\n");
  };
  var cleanTaskChildren = (nodes) => {
    const result = [];
    for (const node of nodes) {
      if (node.type === "element") {
        if (isCheckbox(node))
          continue;
        const cleaned = { ...node, children: cleanTaskChildren(node.children) };
        if (hasHtmlClass(cleaned, "nizel-task-list__label") || hasHtmlClass(cleaned, "nizel-task-list__content")) {
          result.push(...cleaned.children);
        } else {
          result.push(cleaned);
        }
      } else {
        result.push(node);
      }
    }
    return result;
  };
  var transformTaskLists = (ast, mode = "view") => {
    return { ...ast, children: ast.children.map((node) => transformBlock5(node, mode)) };
  };
  var transformBlock5 = (node, mode) => {
    if (node.type === "blockquote")
      return { ...node, children: node.children.map((child) => transformBlock5(child, mode)) };
    if (node.type === "list") {
      return {
        ...node,
        children: node.children.map((item) => {
          const children = item.children.map((child) => transformBlock5(child, mode));
          return item.checked === void 0 ? { ...item, children } : { ...item, children: addCheckbox(children, item.checked, mode) };
        })
      };
    }
    if (node.type === "customBlock")
      return { ...node, children: node.children?.map((child) => transformBlock5(child, mode)) };
    return node;
  };
  var addCheckbox = (children, checked, mode) => {
    const paragraphIndex = children.findIndex((child) => child.type === "paragraph");
    const checkbox = checkboxNode(checked, mode);
    if (paragraphIndex === -1) {
      return [{ type: "paragraph", children: [checkbox] }, ...children];
    }
    return children.map((child, index) => {
      if (index !== paragraphIndex || child.type !== "paragraph")
        return child;
      if (hasTaskCheckbox(child.children))
        return child;
      return {
        ...child,
        children: [
          labelOpenNode(),
          checkbox,
          contentOpenNode(),
          ...child.children,
          contentCloseNode(),
          labelCloseNode()
        ]
      };
    });
  };
  var hasTaskCheckbox = (nodes) => {
    return nodes.some((node) => node.type === "inlineHtml" && node.value.includes("data-nizel-task-checkbox"));
  };
  var checkboxNode = (checked, mode) => ({
    type: "inlineHtml",
    value: `<input class="nizel-task-list__checkbox" data-nizel-task-checkbox type="checkbox"${checked ? " checked" : ""}${mode === "view" ? " disabled" : ""}>`
  });
  var labelOpenNode = () => ({
    type: "inlineHtml",
    value: '<label class="nizel-task-list__label">'
  });
  var labelCloseNode = () => ({
    type: "inlineHtml",
    value: "</label>"
  });
  var contentOpenNode = () => ({
    type: "inlineHtml",
    value: '<span class="nizel-task-list__content">'
  });
  var contentCloseNode = () => ({
    type: "inlineHtml",
    value: "</span>"
  });

  // ../plugin-gfm/dist/index.js
  var gfmPlugins = (options = {}) => [
    ...options.autolinks === false ? [] : [autolinkPlugin()],
    ...options.alerts === false ? [] : [alertPlugin()],
    ...options.taskLists === false ? [] : [taskListPlugin(options.taskLists === true ? void 0 : options.taskLists)]
  ];

  // ../plugin-heading-anchors/dist/index.js
  var headingAnchorsPlugin = (options = {}) => ({
    name: "heading-anchors",
    hooks: {
      afterParse(ast) {
        return addHeadingAnchors(ast, options);
      }
    },
    htmlToMarkdown: headingAnchorsToMarkdown(options)
  });
  var headingAnchorsToMarkdown = (options = {}) => {
    const className = options.className ?? "heading-anchor";
    return (node) => {
      if (node.type !== "element" || node.tag !== "a" || !hasHtmlClass(node, className))
        return void 0;
      return "";
    };
  };
  var addHeadingAnchors = (ast, options = {}) => ({
    ...ast,
    children: ast.children.map((node) => {
      if (node.type !== "heading" || !node.id)
        return node;
      return {
        ...node,
        children: [
          ...node.children,
          {
            type: "inlineHtml",
            value: `<a class="${escapeHtml8(options.className ?? "heading-anchor")}" href="#${escapeHtml8(node.id)}" aria-label="${escapeHtml8(options.ariaLabel ?? "Link to section")}">${escapeHtml8(options.label ?? "")}</a>`
          }
        ]
      };
    })
  });
  var escapeHtml8 = (value) => value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

  // ../nizel-plugin-hidden-comments/dist/index.js
  var hiddenCommentsPlugin = (options = {}) => {
    const normalized = normalizeOptions(options);
    let comments = /* @__PURE__ */ new Map();
    let nextIndex = 0;
    return {
      name: "hidden-comments",
      hooks: {
        beforeParse(markdown) {
          comments = /* @__PURE__ */ new Map();
          nextIndex = 0;
          return transformMarkdownComments(markdown, normalized, (comment) => {
            const token = `NIZEL_HIDDEN_COMMENT_${nextIndex}_${Math.random().toString(36).slice(2)}`;
            nextIndex += 1;
            comments.set(token, comment);
            return token;
          });
        },
        afterRender(html) {
          let nextHtml = restoreCommentTokens(html, comments, normalized);
          if (normalized.injectCss && normalized.mode !== "remove") {
            nextHtml = `${hiddenCommentsStyleTag(normalized.className)}
${nextHtml}`;
          }
          return nextHtml;
        }
      },
      htmlToMarkdown: hiddenCommentsToMarkdown(normalized)
    };
  };
  var transformMarkdownComments = (markdown, options = {}, createToken = (comment) => renderCommentElement(comment, normalizeOptions(options))) => {
    const normalized = normalizeOptions(options);
    if (typeof markdown !== "string" || markdown.indexOf("<!--") === -1)
      return markdown;
    return replaceMarkdownCommentsOutsideFences(markdown, (comment) => {
      if (normalized.mode === "remove")
        return "";
      return createToken(comment);
    });
  };
  var hiddenCommentsToMarkdown = (options = {}) => {
    const normalized = normalizeOptions(options);
    return (node, ctx) => {
      if (node.type !== "element" || node.tag !== "span")
        return void 0;
      if (!isHiddenCommentElement(node.attrs, normalized.className))
        return void 0;
      const text = ctx.text(node).trim();
      if (/^<!--[\s\S]*-->$/.test(text))
        return text;
      return `<!-- ${text.replace(/^<!--|-->$/g, "").trim()} -->`;
    };
  };
  var isHiddenCommentElement = (attrs, className) => {
    if ("data-nizel-hidden-comment" in attrs)
      return true;
    return (attrs.class ?? "").split(/\s+/).includes(className);
  };
  var normalizeOptions = (options) => ({
    mode: options.mode ?? "hide",
    injectCss: options.injectCss ?? false,
    className: options.className ?? "nizel-hidden-comment"
  });
  var replaceMarkdownCommentsOutsideFences = (markdown, replacer) => {
    const lines = markdown.match(/.*(?:\r?\n|$)/g) ?? [];
    let result = "";
    let outsideFence = "";
    let fence;
    const flushOutsideFence = () => {
      if (!outsideFence)
        return;
      result += replaceMarkdownComments(outsideFence, replacer);
      outsideFence = "";
    };
    for (const line of lines) {
      if (line === "")
        continue;
      if (fence) {
        result += line;
        if (isClosingFenceLine(line, fence))
          fence = void 0;
        continue;
      }
      const openingFence = getOpeningFenceLine(line);
      if (openingFence) {
        flushOutsideFence();
        result += line;
        fence = openingFence;
        continue;
      }
      outsideFence += line;
    }
    flushOutsideFence();
    return result;
  };
  var replaceMarkdownComments = (markdown, replacer) => {
    return markdown.replace(/<!--[\s\S]*?-->/g, replacer);
  };
  var getOpeningFenceLine = (line) => {
    const match = /^( {0,3})(`{3,}|~{3,})/.exec(line);
    if (!match)
      return void 0;
    return { marker: match[2].charAt(0), length: match[2].length };
  };
  var isClosingFenceLine = (line, fence) => {
    const lineText = line.replace(/\r?\n$/, "");
    const escapedMarker = fence.marker.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const pattern = new RegExp(`^ {0,3}${escapedMarker}{${fence.length},} *$`);
    return pattern.test(lineText);
  };
  var renderCommentElement = (comment, options) => {
    const classes = [
      options.className,
      `${options.className}--${options.mode}`,
      "print-hidden-comment"
    ];
    const mode = escapeHtml9(options.mode);
    return `<span class="${classes.map(escapeHtml9).join(" ")}" data-nizel-hidden-comment="" data-hidden-comment-mode="${mode}">${escapeHtml9(comment)}</span>`;
  };
  var restoreCommentTokens = (html, comments, options) => {
    if (!comments.size || options.mode === "remove")
      return html;
    let nextHtml = html;
    for (const [token, comment] of comments) {
      const tokenPattern = new RegExp(escapeRegExp2(token), "g");
      const blockPattern = new RegExp(`<p>\\s*${escapeRegExp2(token)}\\s*</p>`, "g");
      const rendered = renderCommentElement(comment, options);
      nextHtml = nextHtml.replace(blockPattern, rendered).replace(tokenPattern, rendered);
    }
    return nextHtml;
  };
  var hiddenCommentsStyleTag = (className) => {
    return `<style data-nizel-plugin="hidden-comments">${hiddenCommentsCss(className)}</style>`;
  };
  var hiddenCommentsCss = (className) => {
    const selector = `.${className.replace(/[^A-Za-z0-9_-]/g, "")}`;
    return `${selector} {
  user-select: text;
}
${selector}--hide {
  border: 0;
  color: rgba(255, 255, 255, 0);
  display: inline-block;
  font-size: 1px;
  height: 0;
  line-height: 0;
  margin: 0;
  max-height: 0;
  max-width: 0;
  overflow: hidden;
  padding: 0;
  vertical-align: baseline;
  width: 0;
}
${selector}--small {
  color: color-mix(in srgb, currentColor 60%, transparent);
  display: inline;
  font-size: 0.75em;
  line-height: 1;
}
${selector}--render {
  display: inline;
}`;
  };
  var escapeHtml9 = (value) => {
    return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  };
  var escapeRegExp2 = (value) => {
    return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  };

  // ../plugin-math/dist/index.js
  var mathPlugin = (options = {}) => {
    return {
      name: "math",
      blocks: {
        math: mathBlock(options)
      },
      hooks: {
        beforeParse: transformBlockMath,
        afterParse(ast) {
          return transformInlineMath(ast, options);
        }
      },
      htmlToMarkdown: mathToMarkdown(options)
    };
  };
  var mathToMarkdown = (options = {}) => {
    const inlineTokens = (options.inlineClassName ?? "math math-inline").split(/\s+/);
    const blockTokens = (options.blockClassName ?? "math math-display").split(/\s+/);
    return (node, ctx) => {
      if (node.type !== "element")
        return void 0;
      const tokens = node.attrs.class ? node.attrs.class.split(/\s+/) : [];
      if (node.tag === "span" && inlineTokens.every((token) => tokens.includes(token))) {
        return `$${ctx.text(node)}$`;
      }
      if (node.tag === "div" && blockTokens.every((token) => tokens.includes(token))) {
        return `$$
${ctx.text(node).trim()}
$$`;
      }
      return void 0;
    };
  };
  var transformBlockMath = (markdown) => {
    const lines = markdown.split("\n");
    const result = [];
    let index = 0;
    while (index < lines.length) {
      if (!/^ {0,3}\$\$\s*$/.test(lines[index])) {
        result.push(lines[index]);
        index += 1;
        continue;
      }
      const content = [];
      index += 1;
      while (index < lines.length && !/^ {0,3}\$\$\s*$/.test(lines[index])) {
        content.push(lines[index]);
        index += 1;
      }
      if (index < lines.length)
        index += 1;
      result.push("::math", ...content, "::");
    }
    return result.join("\n");
  };
  var transformInlineMath = (ast, options = {}) => {
    return { ...ast, children: ast.children.map((node) => transformBlock6(node, options)) };
  };
  var mathBlock = (options) => ({
    name: "math",
    parse({ content }) {
      return { code: content };
    },
    formats: {
      html(node, ctx) {
        if (node.type !== "customBlock")
          return "";
        const code = node.value?.code ?? "";
        return `<div class="${ctx.escape(options.blockClassName ?? "math math-display")}">${ctx.escape(code)}</div>`;
      }
    }
  });
  var transformBlock6 = (node, options) => {
    if (node.type === "paragraph" || node.type === "heading") {
      return { ...node, children: transformInlineNodes2(node.children, options) };
    }
    if (node.type === "blockquote")
      return { ...node, children: node.children.map((child) => transformBlock6(child, options)) };
    if (node.type === "list") {
      return { ...node, children: node.children.map((item) => ({ ...item, children: item.children.map((child) => transformBlock6(child, options)) })) };
    }
    if (node.type === "table") {
      return {
        ...node,
        children: node.children.map((row) => ({
          ...row,
          children: row.children.map((cell) => ({ ...cell, children: transformInlineNodes2(cell.children, options) }))
        }))
      };
    }
    if (node.type === "customBlock")
      return { ...node, children: node.children?.map((child) => transformBlock6(child, options)) };
    return node;
  };
  var transformInlineNodes2 = (nodes, options) => {
    const transformed = [];
    for (const node of nodes) {
      if (node.type === "text")
        transformed.push(...transformText2(node.value, options));
      else if ("children" in node)
        transformed.push({ ...node, children: transformInlineNodes2(node.children, options) });
      else
        transformed.push(node);
    }
    return transformed;
  };
  var transformText2 = (value, options) => {
    const nodes = [];
    const pattern = new RegExp("(?<!\\\\)\\$(?!\\$)([^$\\n]+?)(?<!\\\\)\\$", "g");
    let lastIndex = 0;
    let match;
    while (match = pattern.exec(value)) {
      if (match.index > lastIndex)
        nodes.push({ type: "text", value: value.slice(lastIndex, match.index) });
      nodes.push({
        type: "inlineHtml",
        value: `<span class="${escapeHtml10(options.inlineClassName ?? "math math-inline")}">${escapeHtml10(match[1])}</span>`
      });
      lastIndex = pattern.lastIndex;
    }
    if (lastIndex < value.length)
      nodes.push({ type: "text", value: value.slice(lastIndex) });
    return nodes;
  };
  var escapeHtml10 = (value) => value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

  // ../plugin-media/dist/index.js
  var mediaPlugin = (options = {}) => ({
    name: "media",
    hooks: {
      afterRender(html) {
        return enhanceImages(html, options);
      }
    },
    htmlToMarkdown: mediaToMarkdown(options)
  });
  var mediaToMarkdown = (options = {}) => {
    const className = options.figureClassName ?? "media-figure";
    return (node, ctx) => {
      if (node.type !== "element" || node.tag !== "figure" || node.attrs.class !== className)
        return void 0;
      const img = findHtmlElement(node, (el) => el.tag === "img");
      if (!img)
        return void 0;
      const attrs = { src: img.attrs.src ?? "" };
      if (img.attrs.alt !== void 0)
        attrs.alt = img.attrs.alt;
      if (img.attrs.title !== void 0)
        attrs.title = img.attrs.title;
      const cleanImg = { type: "element", tag: "img", attrs, children: [], raw: "" };
      return ctx.inline({ type: "root", children: [cleanImg] });
    };
  };
  var enhanceImages = (html, options = {}) => {
    const lazy = options.lazy !== false;
    const responsive = options.responsive !== false;
    const className = options.figureClassName ?? "media-figure";
    return html.replace(/<p>(<img\b[^>]*>)<\/p>/g, (_match, img) => {
      const enhanced = enhanceImageTag(img, { lazy, responsive });
      const caption = /alt="([^"]+)"/.exec(enhanced)?.[1];
      return `<figure class="${escapeHtml11(className)}">${enhanced}${caption ? `<figcaption>${caption}</figcaption>` : ""}</figure>`;
    });
  };
  var enhanceImageTag = (img, options) => {
    let next = img;
    if (options.lazy && !/\sloading=/.test(next))
      next = next.replace(/\/?>$/, ' loading="lazy" />');
    if (options.responsive && !/\sdecoding=/.test(next))
      next = next.replace(/\/?>$/, ' decoding="async" />');
    return next;
  };
  var escapeHtml11 = (value) => value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

  // ../plugin-sanitize/dist/index.js
  var sanitizePlugin = (options = {}) => ({
    name: "sanitize",
    options: {
      safe: options.allowRawHtml === true ? false : true
    },
    hooks: {
      afterRender(html) {
        return sanitizeHtml(html);
      }
    }
  });
  var sanitizeHtml = (html) => {
    return html.replace(/<script\b[\s\S]*?<\/script>/gi, "").replace(/<style\b[\s\S]*?<\/style>/gi, "").replace(/\s+on[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/gi, "").replace(/\s+(href|src)\s*=\s*(["'])\s*javascript:[\s\S]*?\2/gi, "").replace(/\s+(href|src)\s*=\s*javascript:[^\s>]+/gi, "");
  };

  // ../plugin-shiki/dist/index.js
  var shikiPlugin = (options = {}) => {
    const mode = options.mode ?? "blocks";
    const highlighter = options.highlighter;
    return defineNizelPlugin({
      name: "shiki",
      blocks: {
        code: {
          name: "code",
          formats: {
            html(node, ctx) {
              if (node.type !== "code")
                return "";
              if (mode === "inline")
                return fallback(node, ctx);
              const highlighted = highlighter?.(node.code, {
                lang: node.lang,
                theme: options.theme,
                meta: node.meta,
                filename: node.filename,
                highlightLines: node.highlightLines
              });
              return typeof highlighted === "string" ? highlighted : fallback(node, ctx);
            }
          }
        }
      },
      htmlToMarkdown: shikiToMarkdown()
    });
  };
  var shikiToMarkdown = () => (node, ctx) => {
    if (node.type !== "element" || node.tag !== "pre")
      return void 0;
    const isShiki = hasHtmlClass(node, "shiki") || node.attrs.style !== void 0 || node.attrs["data-language"] !== void 0;
    if (!isShiki)
      return void 0;
    const codeEl = findHtmlElement(node, (el) => el.tag === "code");
    const codeClass = codeEl?.attrs.class ?? "";
    const langClass = codeClass.match(/\blanguage-([A-Za-z0-9_-]+)/)?.[1];
    const lang = node.attrs["data-language"] ?? langClass ?? "";
    const code = ctx.text(node).replace(/\n$/, "");
    const fence = fenceFor2(code);
    return `${fence}${lang}
${code}
${fence}`;
  };
  var fenceFor2 = (code) => {
    const longest = Math.max(0, ...(code.match(/`+/g) ?? []).map((run) => run.length));
    return "`".repeat(Math.max(3, longest + 1));
  };
  var fallback = (node, ctx) => {
    const language = node.lang ? ` class="language-${ctx.escape(node.lang)}"` : "";
    return `<pre><code${language}>${ctx.escape(node.code)}</code></pre>`;
  };

  // ../plugin-toc/dist/index.js
  var tocPlugin = (options = {}) => ({
    name: "toc",
    blocks: {
      toc: tocBlock(options)
    },
    hooks: {
      beforeParse(markdown) {
        return markdown.replace(/^\[\[toc\]\]\s*$/gim, "::toc\n::");
      },
      afterParse(ast) {
        return fillTocBlocks(ast, options);
      }
    },
    htmlToMarkdown: tocToMarkdown(options)
  });
  var tocToMarkdown = (options = {}) => {
    const className = options.className ?? "toc";
    return (node) => {
      if (node.type !== "element" || node.tag !== "nav" || !hasHtmlClass(node, className))
        return void 0;
      return "[[toc]]";
    };
  };
  var fillTocBlocks = (ast, options = {}) => {
    const minDepth = options.minDepth ?? 2;
    const maxDepth = options.maxDepth ?? 6;
    const headings = ast.children.filter((node) => node.type === "heading" && Boolean(node.id)).filter((node) => node.depth >= minDepth && node.depth <= maxDepth).map((node) => ({ id: node.id ?? "", text: node.text, depth: node.depth }));
    return {
      ...ast,
      children: ast.children.map((node) => node.type === "customBlock" && node.name === "toc" ? { ...node, value: { items: headings } } : node)
    };
  };
  var tocBlock = (options) => ({
    name: "toc",
    parse() {
      return { items: [] };
    },
    formats: {
      html(node, ctx) {
        if (node.type !== "customBlock")
          return "";
        const items = node.value?.items ?? [];
        const body = items.map((item) => `<li data-depth="${item.depth}"><a href="#${ctx.escape(item.id)}">${ctx.escape(item.text)}</a></li>`).join("");
        return `<nav class="${ctx.escape(options.className ?? "toc")}"><ol>${body}</ol></nav>`;
      }
    }
  });

  // ../plugin-typography/dist/index.js
  var typographyPlugin = (options = {}) => {
    return {
      name: "typography",
      hooks: {
        afterParse(ast) {
          return transformTypography(ast, options);
        }
      },
      htmlToMarkdown: typographyToMarkdown(options)
    };
  };
  var typographyToMarkdown = (options = {}) => {
    const mark = options.mark !== false;
    const subscript = options.subscript !== false;
    const superscript = options.superscript !== false;
    return (node, ctx) => {
      if (node.type !== "element" || Object.keys(node.attrs).length > 0)
        return void 0;
      if (node.tag === "mark" && mark)
        return `==${ctx.inline(node)}==`;
      if (node.tag === "sub" && subscript)
        return `~${ctx.inline(node)}~`;
      if (node.tag === "sup" && superscript)
        return `^${ctx.inline(node)}^`;
      return void 0;
    };
  };
  var transformTypography = (ast, options = {}) => {
    return { ...ast, children: ast.children.map((node) => transformBlock7(node, options)) };
  };
  var transformBlock7 = (node, options) => {
    if (node.type === "paragraph" || node.type === "heading") {
      return { ...node, children: transformInlineNodes3(node.children, options) };
    }
    if (node.type === "blockquote")
      return { ...node, children: node.children.map((child) => transformBlock7(child, options)) };
    if (node.type === "list") {
      return {
        ...node,
        children: node.children.map((item) => ({ ...item, children: item.children.map((child) => transformBlock7(child, options)) }))
      };
    }
    if (node.type === "table") {
      return {
        ...node,
        children: node.children.map((row) => ({
          ...row,
          children: row.children.map((cell) => ({ ...cell, children: transformInlineNodes3(cell.children, options) }))
        }))
      };
    }
    if (node.type === "customBlock")
      return { ...node, children: node.children?.map((child) => transformBlock7(child, options)) };
    return node;
  };
  var transformInlineNodes3 = (nodes, options) => {
    const transformed = [];
    for (const node of nodes) {
      if (node.type === "text") {
        transformed.push(...transformText3(node.value, options));
      } else if ("children" in node) {
        transformed.push({ ...node, children: transformInlineNodes3(node.children, options) });
      } else {
        transformed.push(node);
      }
    }
    return transformed;
  };
  var transformText3 = (value, options) => {
    const mark = options.mark !== false;
    const subscript = options.subscript !== false;
    const superscript = options.superscript !== false;
    const nodes = [];
    const pattern = new RegExp("==([^=\\n]+)==|(?<!~)~([^~\\n]+)~(?!~)|(?<!\\\\)\\^([^^\\n]+)\\^", "g");
    let lastIndex = 0;
    let match;
    while (match = pattern.exec(value)) {
      if (match.index > lastIndex)
        nodes.push({ type: "text", value: value.slice(lastIndex, match.index) });
      if (match[1] !== void 0 && mark)
        nodes.push({ type: "inlineHtml", value: `<mark>${escapeHtml12(match[1])}</mark>` });
      else if (match[2] !== void 0 && subscript)
        nodes.push({ type: "inlineHtml", value: `<sub>${escapeHtml12(match[2])}</sub>` });
      else if (match[3] !== void 0 && superscript)
        nodes.push({ type: "inlineHtml", value: `<sup>${escapeHtml12(match[3])}</sup>` });
      else
        nodes.push({ type: "text", value: match[0] });
      lastIndex = pattern.lastIndex;
    }
    if (lastIndex < value.length)
      nodes.push({ type: "text", value: value.slice(lastIndex) });
    return nodes;
  };
  var escapeHtml12 = (value) => value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

  // src/index.ts
  var supportedPlugins = [
    {
      id: "sanitize",
      label: "Sanitize Output",
      description: "Remove risky HTML from rendered output.",
      defaultEnabled: true,
      category: "core-behavior"
    },
    {
      id: "autolink",
      label: "Autolinks",
      description: "Configure bare URL and email autolinking.",
      defaultEnabled: true,
      category: "core-behavior"
    },
    {
      id: "gfm",
      label: "GFM Preset",
      description: "Enable the GFM-oriented companion plugin set.",
      defaultEnabled: false,
      category: "core-behavior"
    },
    {
      id: "emoji",
      label: "Emoji Shortcodes",
      description: "Replace :name: emoji shortcodes outside code.",
      defaultEnabled: false,
      category: "inline"
    },
    {
      id: "abbr",
      label: "Abbreviations",
      description: "Render abbreviation definitions as abbr elements.",
      defaultEnabled: false,
      category: "inline"
    },
    {
      id: "citations",
      label: "Citations",
      description: "Render simple citation references and bibliography entries.",
      defaultEnabled: false,
      category: "inline"
    },
    {
      id: "alert",
      label: "Alerts",
      description: "Render GitHub-style [!NOTE] callouts and alert custom blocks.",
      defaultEnabled: false,
      category: "block"
    },
    {
      id: "details",
      label: "Details",
      description: "Render disclosure blocks.",
      defaultEnabled: false,
      category: "block"
    },
    {
      id: "deflist",
      label: "Definition Lists",
      description: "Render Term / : Definition blocks.",
      defaultEnabled: false,
      category: "block"
    },
    {
      id: "frontmatter-ui",
      label: "Frontmatter UI",
      description: "Render metadata helper UI blocks.",
      defaultEnabled: false,
      category: "block"
    },
    {
      id: "heading-anchors",
      label: "Heading Anchors",
      description: "Add visible anchor links to headings.",
      defaultEnabled: false,
      category: "block"
    },
    {
      id: "hidden-comments",
      label: "Hidden Comments",
      description: "Control how Markdown HTML comments render in documents.",
      defaultEnabled: false,
      category: "core-behavior"
    },
    {
      id: "media",
      label: "Media",
      description: "Enhance standalone images as native-friendly figures.",
      defaultEnabled: false,
      category: "block"
    },
    {
      id: "toc",
      label: "Table of Contents",
      description: "Render [[toc]] from document headings.",
      defaultEnabled: false,
      category: "block"
    },
    {
      id: "task-list",
      label: "Task Lists",
      description: "Render parsed task-list items as view-only or editable checkboxes.",
      defaultEnabled: false,
      category: "block"
    },
    {
      id: "footnotes",
      label: "Footnotes",
      description: "Render [^id] references and definitions.",
      defaultEnabled: false,
      category: "block"
    },
    {
      id: "math",
      label: "Math",
      description: "Wrap inline $math$ and display $$ math for KaTeX or MathJax.",
      defaultEnabled: false,
      category: "inline"
    },
    {
      id: "typography",
      label: "Typography",
      description: "Render ==mark==, subscript, and superscript extensions.",
      defaultEnabled: false,
      category: "inline"
    },
    {
      id: "diagrams",
      label: "Diagrams",
      description: "Render explicit Mermaid code fences as diagram containers.",
      defaultEnabled: false,
      category: "code"
    },
    {
      id: "shiki",
      label: "Code Highlighting",
      description: "Use a supplied Shiki-compatible highlighter for code blocks.",
      defaultEnabled: false,
      category: "code"
    },
    {
      id: "code-copy",
      label: "Code Copy",
      description: "Render code blocks with copy button markup.",
      defaultEnabled: false,
      category: "code"
    }
  ];
  var factories = {
    abbr: (options) => abbrPlugin(options.abbr),
    alert: (options) => alertPlugin(options.alert),
    autolink: (options) => autolinkPlugin(options.autolink),
    citations: (options) => citationsPlugin(options.citations),
    "code-copy": (options) => codeCopyPlugin(options["code-copy"]),
    deflist: (options) => deflistPlugin(options.deflist),
    details: (options) => detailsPlugin(options.details),
    diagrams: (options) => diagramsPlugin(options.diagrams),
    emoji: (options) => emojiPlugin(options.emoji),
    footnotes: (options) => footnotesPlugin(options.footnotes),
    "frontmatter-ui": (options) => frontmatterUiPlugin(options["frontmatter-ui"]),
    gfm: (options) => gfmPlugins(options.gfm),
    "heading-anchors": (options) => headingAnchorsPlugin(options["heading-anchors"]),
    "hidden-comments": (options) => hiddenCommentsPlugin(options["hidden-comments"]),
    math: (options) => mathPlugin(options.math),
    media: (options) => mediaPlugin(options.media),
    sanitize: (options) => sanitizePlugin(options.sanitize),
    shiki: (options) => shikiPlugin(options.shiki),
    "task-list": (options) => taskListPlugin(options["task-list"]),
    toc: (options) => tocPlugin(options.toc),
    typography: (options) => typographyPlugin(options.typography)
  };
  var defaultEnabledPlugins = () => {
    return supportedPlugins.filter((plugin) => plugin.defaultEnabled).map((plugin) => plugin.id);
  };
  var createPlugins = (enabledPlugins = defaultEnabledPlugins(), options = {}) => {
    return normalizeEnabledPlugins(enabledPlugins).flatMap((id) => factories[id](options));
  };
  function useNizelKit(options = {}) {
    const { enabledPlugins, pluginOptions, plugins = [], ...nizelOptions } = options;
    const resolvedPlugins = [...createPlugins(enabledPlugins, pluginOptions), ...plugins];
    const processor = useBrowserNizel({
      ...nizelOptions,
      plugins: resolvedPlugins
    });
    const htmlToMarkdown3 = processor.htmlToMarkdown.bind(processor);
    processor.htmlToMarkdown = (source, reverseOptions) => {
      return htmlToMarkdown3(source, withKitHtmlToMarkdownPlugins(reverseOptions, resolvedPlugins));
    };
    const nodeToMarkdown2 = processor.nodeToMarkdown.bind(processor);
    processor.nodeToMarkdown = (source, reverseOptions) => {
      return nodeToMarkdown2(source, withKitHtmlToMarkdownPlugins(reverseOptions, resolvedPlugins));
    };
    const selectionToMarkdown2 = processor.selectionToMarkdown.bind(processor);
    processor.selectionToMarkdown = (selection, reverseOptions) => {
      return selectionToMarkdown2(selection, withKitHtmlToMarkdownPlugins(reverseOptions, resolvedPlugins));
    };
    return processor;
  }
  var withKitHtmlToMarkdownPlugins = (options, plugins) => {
    return {
      ...options,
      plugins: [...plugins, ...options?.plugins ?? []]
    };
  };
  async function markdownToHtml(markdown, options) {
    return useNizelKit(options).html(markdown);
  }
  async function mountMarkdown2(target, markdown, options) {
    return useNizelKit(options).mount(target, markdown);
  }
  var normalizeEnabledPlugins = (enabledPlugins) => {
    const validIds = new Set(supportedPlugins.map((plugin) => plugin.id));
    const exclusiveGroups = /* @__PURE__ */ new Map();
    const normalized = [];
    for (const id of enabledPlugins) {
      if (!validIds.has(id)) continue;
      const meta = supportedPlugins.find((plugin) => plugin.id === id);
      if (meta?.exclusiveGroup) {
        exclusiveGroups.set(meta.exclusiveGroup, id);
        continue;
      }
      if (!normalized.includes(id)) normalized.push(id);
    }
    for (const id of exclusiveGroups.values()) {
      if (!normalized.includes(id)) normalized.push(id);
    }
    return normalized;
  };
  return __toCommonJS(index_exports);
})();
