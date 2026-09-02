.pragma library

// Strings from the marketplace APIs are untrusted. Every Text in this plugin is
// PlainText, but the bar label and tooltip are rendered by the shell's own
// AutoText elements, so those two are scrubbed again at the boundary.

function plainOneLine(value, maxLength) {
  var text = String(value === undefined || value === null ? "" : value)
  text = text.replace(/[\x00-\x1f\x7f]/g, " ")
  text = text.replace(/[<>&]/g, "")
  text = text.replace(/\s+/g, " ")
  text = text.replace(/^\s+|\s+$/g, "")
  var limit = maxLength > 0 ? maxLength : 120
  return text.length > limit ? text.substring(0, limit - 1) + "…" : text
}

// Applied wholesale to the exported bar strings, never to the fields feeding them.
function barSafe(value) {
  var input = String(value === undefined || value === null ? "" : value)
  var out = ""
  for (var i = 0; i < input.length && out.length < 200; i++) {
    var code = input.charCodeAt(i)
    var ch = input.charAt(i)
    if (code < 32 || code === 127 || ch === "<" || ch === ">" || ch === "&") { out += " "; continue }
    out += ch
  }
  return out.replace(/\s+/g, " ").trim()
}

function pluginId(value) {
  var text = String(value === undefined || value === null ? "" : value)
  return /^[a-z0-9][a-z0-9._-]{0,127}$/.test(text) && text.indexOf("..") < 0 ? text : ""
}

function author(value) {
  var text = plainOneLine(value, 120).toLowerCase()
  return text.replace(/[^a-z0-9 ._-]/g, "")
}
