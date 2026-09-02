.pragma library

// A deliberately small Markdown-to-blocks reader for untrusted READMEs.
// Output is plain text per block; nothing here ever becomes rich text.

function decodeEntities(text) {
  return text.replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
             .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, " ")
}

function inline(text) {
  var t = String(text || "")
  t = t.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, "")
  t = t.replace(/!\[([^\]]*)\]\([^)]*\)/g, function (_, alt) { return alt ? "⟨image: " + alt + "⟩" : "" })
  t = t.replace(/\[([^\]]+)\]\((https:\/\/[^)\s]+)(?:\s+"[^"]*")?\)/g, "$1 ‹$2›")
  t = t.replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
  t = t.replace(/<br\s*\/?>/gi, "\n")
  t = t.replace(/<[^>]{1,200}>/g, "")
  t = t.replace(/(\*\*|__)(.+?)\1/g, "$2")
  t = t.replace(/(^|[\s(])[*_]([^*_\n]+)[*_](?=[\s).,;:!?]|$)/g, "$1$2")
  t = t.replace(/~~(.+?)~~/g, "$1")
  t = t.replace(/`([^`\n]+)`/g, "$1")
  t = decodeEntities(t)
  return t
}

function imageOnly(text) {
  var stripped = String(text || "").replace(/⟨image:[^⟩]*⟩/g, "").replace(/‹[^›]*›/g, "").trim()
  return stripped === "" && /⟨image:/.test(text)
}

// Returns [{type, level, text}] with type in heading, para, code, list, quote, table, hr.
function parse(source, maxBlocks) {
  var limit = maxBlocks > 0 ? maxBlocks : 600
  var lines = String(source || "").replace(/\r\n?/g, "\n").split("\n")
  var blocks = []
  var para = [], code = null, list = [], quote = [], table = []

  function flushPara() {
    if (para.length) {
      var text = inline(para.join(" ").replace(/\s+/g, " ").trim())
      if (text !== "" && !imageOnly(text)) blocks.push({ type: "para", text: text })
      para = []
    }
  }
  function flushList() {
    if (list.length) { blocks.push({ type: "list", text: list.join("\n") }); list = [] }
  }
  function flushQuote() {
    if (quote.length) { blocks.push({ type: "quote", text: inline(quote.join(" ")) }); quote = [] }
  }
  function flushTable() {
    if (table.length) { blocks.push({ type: "table", text: table.join("\n") }); table = [] }
  }
  function flushAll() { flushPara(); flushList(); flushQuote(); flushTable() }

  for (var i = 0; i < lines.length && blocks.length < limit; i++) {
    var line = lines[i]
    var fence = line.match(/^\s*(```|~~~)/)
    if (code !== null) {
      if (fence) { blocks.push({ type: "code", text: code.join("\n") }); code = null }
      else code.push(line.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, ""))
      continue
    }
    if (fence) { flushAll(); code = []; continue }

    if (/^\s*$/.test(line)) { flushAll(); continue }

    var h = line.match(/^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$/)
    if (h) { flushAll(); blocks.push({ type: "heading", level: h[1].length, text: inline(h[2]) }); continue }

    if (/^\s{0,3}([-*_])(\s*\1){2,}\s*$/.test(line)) { flushAll(); blocks.push({ type: "hr", text: "" }); continue }

    // Setext headings: a paragraph line followed by === or ---.
    if (para.length && /^\s{0,3}(=+|-+)\s*$/.test(line)) {
      var text = inline(para.join(" "))
      para = []
      blocks.push({ type: "heading", level: line.trim().charAt(0) === "=" ? 1 : 2, text: text })
      continue
    }

    if (/^\s*\|/.test(line)) {
      flushPara(); flushList(); flushQuote()
      if (/^\s*\|?\s*:?-{2,}/.test(line)) continue
      table.push(inline(line).replace(/^\s*\|/, "").replace(/\|\s*$/, "").split("|").map(function (c) { return c.trim() }).join("   "))
      continue
    }

    var q = line.match(/^\s{0,3}>\s?(.*)$/)
    if (q) { flushPara(); flushList(); flushTable(); quote.push(q[1]); continue }

    var li = line.match(/^\s*(?:[-*+]|\d+[.)])\s+(.*)$/)
    if (li) { flushPara(); flushQuote(); flushTable(); list.push("•  " + inline(li[1])); continue }

    if (list.length && /^\s{2,}\S/.test(line)) { list[list.length - 1] += " " + inline(line.trim()); continue }

    flushList(); flushQuote(); flushTable()
    para.push(line.trim())
  }
  if (code !== null) blocks.push({ type: "code", text: code.join("\n") })
  flushAll()
  return blocks
}
