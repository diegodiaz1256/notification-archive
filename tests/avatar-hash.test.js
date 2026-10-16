// Shared FNV-1a test vectors for the avatar file name. The same hash is
// implemented in the Rust daemon (notification-archive/avatar-daemon) and in
// both plugins' Panel.qml. Keep these vectors identical in every copy.
// Run: node tests/avatar-hash.test.js
const fs = require("fs")
const path = require("path")

const VECTORS = {
  "": "cbf29ce484222325",
  "Alba Galleguiña": "c50ec1f6f3642070",
  "Contact": "87bae2710b2492c3",
  "Someone Else": "1aadd9b38e37b924",
  "Ana 😀": "dfad939d85380b8e"
}

const src = fs.readFileSync(path.join(__dirname, "..", "Panel.qml"), "utf8")
function extract(name) {
  const start = src.indexOf("  function " + name + "(")
  if (start < 0) throw new Error("function not found in Panel.qml: " + name)
  const open = src.indexOf("{", start)
  let depth = 0
  for (let i = open; i < src.length; i++) {
    if (src[i] === "{") depth++
    else if (src[i] === "}" && --depth === 0) return src.slice(start, i + 1)
  }
  throw new Error("unbalanced braces in " + name)
}

const root = {}
new Function("root", extract("utf8Bytes").replace("function utf8Bytes", "root.utf8Bytes = function") + "\n" +
  extract("avatarHash").replace("function avatarHash", "root.avatarHash = function"))(root)

let failed = 0
for (const [text, want] of Object.entries(VECTORS)) {
  const got = root.avatarHash(text)
  if (got !== want) { failed++; console.error("FAIL", JSON.stringify(text), got, "!=", want) }
}
if (failed) process.exit(1)
console.log("ok: " + Object.keys(VECTORS).length + " vectors")
