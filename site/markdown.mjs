// A small Markdown renderer for the docs pages, with no dependencies. It
// handles what docs/ uses: headings, paragraphs, lists (nested, with code in
// items), fenced code, tables, block quotes, rules, and inline code, links,
// bold and italics. Everything is escaped; raw HTML in the Markdown shows as
// text.
//
//   render(markdown, { link(href) -> href, afterHeading(level, text, id) -> html })
//     -> { html, headings: [{ level, text, id }] }

export function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

/** GitHub's heading ids: lower case, punctuation dropped, spaces to dashes. */
export function slug(text) {
  return text.toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, "").trim().replace(/\s/g, "-");
}

const LIST = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/;
const FENCE = /^(\s*)(`{3,}|~{3,})\s*([\w+-]*)\s*$/;
const indentOf = (l) => l.match(/^ */)[0].length;
const isTableRow = (l) => /^\s*\|/.test(l);
const isRule = (l) => /^\s{0,3}([-*_])(\s*\1){2,}\s*$/.test(l);

function startsBlock(l) {
  return FENCE.test(l) || /^#{1,6}\s/.test(l) || isRule(l) || isTableRow(l) || /^\s*>/.test(l) || LIST.test(l);
}

export function render(markdown, opts = {}) {
  const ctx = { link: opts.link || ((h) => h), afterHeading: opts.afterHeading || (() => ""), headings: [], ids: new Map() };
  const html = blocks(markdown.replace(/\r/g, "").split("\n"), ctx);
  return { html, headings: ctx.headings };
}

function blocks(lines, ctx) {
  const out = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { i++; continue; }
    let m = line.match(FENCE);
    if (m) {
      const indent = m[1].length, fence = m[2], body = [];
      for (i++; i < lines.length && !(lines[i].trim().startsWith(fence[0].repeat(fence.length)) && lines[i].trim().replace(/[`~]/g, "") === ""); i++) {
        body.push(lines[i].slice(Math.min(indent, indentOf(lines[i]))));
      }
      i++;
      out.push(code(body.join("\n"), m[3]));
      continue;
    }
    m = line.match(/^(#{1,6})\s+(.*?)\s*#*\s*$/);
    if (m) {
      out.push(heading(m[1].length, m[2], ctx));
      i++;
      continue;
    }
    if (isRule(line)) { out.push("<hr>"); i++; continue; }
    if (isTableRow(line) && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1])) {
      const head = cells(line), aligns = cells(lines[i + 1]).map((c) => (/^:-+:$/.test(c) ? "center" : /-:$/.test(c) ? "right" : null));
      const rows = [];
      for (i += 2; i < lines.length && isTableRow(lines[i]); i++) rows.push(cells(lines[i]));
      const td = (tag, c, k) => `<${tag}${aligns[k] ? ` style="text-align:${aligns[k]}"` : ""}>${inline(c, ctx)}</${tag}>`;
      out.push(`<div class="table"><table><thead><tr>${head.map((c, k) => td("th", c, k)).join("")}</tr></thead><tbody>${rows.map((r) => `<tr>${head.map((_, k) => td("td", r[k] || "", k)).join("")}</tr>`).join("")}</tbody></table></div>`);
      continue;
    }
    if (/^\s*>/.test(line)) {
      const body = [];
      for (; i < lines.length && lines[i].trim() && (/^\s*>/.test(lines[i]) || !startsBlock(lines[i])); i++) body.push(lines[i].replace(/^\s*> ?/, ""));
      out.push(`<blockquote>${blocks(body, ctx)}</blockquote>`);
      continue;
    }
    m = line.match(LIST);
    if (m) {
      const r = list(lines, i, ctx);
      out.push(r.html);
      i = r.next;
      continue;
    }
    const para = [line.trim()];
    for (i++; i < lines.length && lines[i].trim() && !startsBlock(lines[i]); i++) para.push(lines[i].trim());
    out.push(`<p>${inline(para.join("\n"), ctx)}</p>`);
  }
  return out.join("\n");
}

function list(lines, start, ctx) {
  const first = lines[start].match(LIST);
  const base = first[1].length, ordered = /\d/.test(first[2]);
  const items = [];
  let i = start, loose = false;
  while (i < lines.length) {
    const m = lines[i].match(LIST);
    if (!m || m[1].length !== base || /\d/.test(m[2]) !== ordered) break;
    const content = lines[i].length - m[3].length;
    const body = [m[3]];
    let blank = false;
    for (i++; i < lines.length; i++) {
      const l = lines[i];
      if (!l.trim()) {
        let j = i + 1;
        while (j < lines.length && !lines[j].trim()) j++;
        if (j < lines.length && indentOf(lines[j]) > base) { body.push(""); blank = true; continue; }
        break;
      }
      if (indentOf(l) > base) { body.push(l.slice(Math.min(indentOf(l), content))); continue; }
      if (!blank && !startsBlock(l)) { body.push(l); continue; } // a lazy continuation
      break;
    }
    if (blank && body.slice(1).some((l) => l.trim() && !LIST.test(l) && !FENCE.test(l))) loose = true;
    items.push(body);
    let j = i;
    while (j < lines.length && !lines[j].trim()) j++;
    const n = j < lines.length && lines[j].match(LIST);
    if (n && n[1].length === base && /\d/.test(n[2]) === ordered) { if (j > i) loose = true; i = j; continue; }
    break;
  }
  const tag = ordered ? "ol" : "ul";
  const startAt = ordered && parseInt(first[2], 10) !== 1 ? ` start="${parseInt(first[2], 10)}"` : "";
  const lis = items.map((body) => {
    let html = blocks(body, ctx);
    if (!loose) html = html.replace(/^<p>([\s\S]*?)<\/p>/, "$1");
    return `<li>${html}</li>`;
  });
  return { html: `<${tag}${startAt}>${lis.join("\n")}</${tag}>`, next: i };
}

function cells(row) {
  const s = row.trim().replace(/^\|/, "").replace(/\|$/, "");
  const out = [];
  let cur = "", tick = 0;
  for (let k = 0; k < s.length; k++) {
    const c = s[k];
    if (c === "\\" && s[k + 1] === "|") { cur += "|"; k++; continue; }
    if (c === "`") tick ^= 1;
    if (c === "|" && !tick) { out.push(cur.trim()); cur = ""; continue; }
    cur += c;
  }
  out.push(cur.trim());
  return out;
}

function heading(level, raw, ctx) {
  const text = plain(raw);
  let id = slug(text);
  const n = ctx.ids.get(id) || 0;
  ctx.ids.set(id, n + 1);
  if (n) id = `${id}-${n}`;
  ctx.headings.push({ level, text, id });
  const anchor = level > 1 ? ` <a class="anchor" href="#${id}" aria-label="Link to this section">#</a>` : "";
  return `<h${level} id="${id}">${inline(raw, ctx)}${anchor}</h${level}>${ctx.afterHeading(level, text, id) || ""}`;
}

/** The text of inline Markdown, without its markup. */
export function plain(raw) {
  return raw.replace(/`+([^`]*)`+/g, "$1").replace(/\[([^\]]*)\]\([^)]*\)/g, "$1").replace(/\*\*([^*]+)\*\*/g, "$1").replace(/\\([\\`*_{}[\]()#+\-.!|<>])/g, "$1");
}

// Code spans, links and autolinks, in the order they appear; emphasis in the text between.
const INLINE = /(`+)([\s\S]+?)\1(?!`)|\[((?:[^[\]`]|`[^`]*`)+)\]\(([^)\s]+)\)|<(https?:\/\/[^>\s]+)>/g;

function inline(s, ctx) {
  let out = "", last = 0, m;
  const re = new RegExp(INLINE.source, "g"); // its own: link text recurses
  while ((m = re.exec(s))) {
    out += emphasis(s.slice(last, m.index));
    if (m[1]) out += `<code>${esc(m[2].replace(/^ (.*) $/, "$1"))}</code>`;
    else if (m[3]) out += `<a href="${esc(ctx.link(m[4]))}">${inline(m[3], ctx)}</a>`;
    else out += `<a href="${esc(m[5])}">${esc(m[5])}</a>`;
    last = re.lastIndex;
  }
  return out + emphasis(s.slice(last));
}

function emphasis(text) {
  const keep = [];
  let s = text.replace(/\\([\\`*_{}[\]()#+\-.!|<>])/g, (_, c) => { keep.push(c); return `\u0000${keep.length - 1}\u0000`; });
  s = esc(s);
  s = s.replace(/\*\*(?=\S)([\s\S]*?\S)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/(^|[^\w*])\*(?=\S)([^*]*?\S)\*(?![\w*])/g, "$1<em>$2</em>");
  s = s.replace(/(^|[^\w])_(?=\S)([^_]*?\S)_(?!\w)/g, "$1<em>$2</em>");
  return s.replace(/\u0000(\d+)\u0000/g, (_, k) => esc(keep[+k]));
}

// MARK: Code

function code(text, lang) {
  const l = (lang || "").toLowerCase();
  let body;
  if (l === "json" || l === "jsonc") body = highlightJSON(text);
  else if (l === "nix") body = highlightNix(text);
  else if (l === "sh" || l === "shell" || l === "bash") body = esc(text).replace(/^(\s*#.*)$/gm, '<span class="c">$1</span>');
  else body = esc(text);
  const label = l && l !== "text" ? `<span class="lang">${esc(l === "jsonc" ? "json" : l)}</span>` : "";
  return `<div class="codeblock" data-lang="${esc(l)}">${label}<pre class="code">${body}</pre><button class="copy-code" type="button" data-copy="${esc(text)}"><span class="copy">Copy</span></button></div>`;
}

export function highlightJSON(text) {
  return esc(text).replace(/(\/\/[^\n]*)|(&quot;(?:[^&\\]|\\.|&(?!quot;))*?&quot;)(\s*:)?|\b(true|false|null|-?\d+(?:\.\d+)?)\b/g, (m, comment, str, colon, lit) => {
    if (comment) return `<span class="c">${comment}</span>`;
    if (str) return colon ? `<span class="k">${str}</span>${colon}` : `<span class="s">${str}</span>`;
    return `<span class="n">${lit}</span>`;
  });
}

function highlightNix(text) {
  return esc(text).replace(/(#[^\n]*)|(&#39;&#39;[\s\S]*?&#39;&#39;|&quot;(?:[^&\\]|\\.|&(?!quot;))*?&quot;)|\b(true|false|null|\d+(?:\.\d+)?)\b/g, (m, comment, str, lit) => {
    if (comment) return `<span class="c">${comment}</span>`;
    if (str) return `<span class="s">${str}</span>`;
    return `<span class="n">${lit}</span>`;
  });
}
