"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");

const web = resolve(__dirname, "..");
const app = readFileSync(resolve(web, "app.js"), "utf8");
const server = readFileSync(resolve(web, "..", "server.py"), "utf8");

assert.match(server, /class GeminiRequestError/, "backend must preserve safe Gemini diagnostics");
assert.match(server, /"gemini_http_timeout"/, "backend must identify HTTP read timeouts");
assert.match(server, /"contextBytes"/, "backend must report context size without logging its contents");
assert.match(server, /"geminiHttpMs"/, "backend must report upstream HTTP elapsed time");
assert.match(server, /"timeoutMs"/, "backend must report configured timeout limit");
assert.match(app, /clientDiagnostics: \{ snapshotMs, evidenceMs, contextBytes \}/, "client must time local preparation");
assert.match(app, /type: "GEMINI_TIMEOUT"/, "timeout must become a session Event Log entry");
assert.match(app, /PHASE \$\{diagnostics\.phase/, "Event Log detail must include failure phase");
assert.match(app, /CONTEXT \$\{diagnostics\.contextBytes \?\? contextBytes\} B/, "Event Log detail must include context size only");

console.log("gemini timeout diagnostics tests passed");
