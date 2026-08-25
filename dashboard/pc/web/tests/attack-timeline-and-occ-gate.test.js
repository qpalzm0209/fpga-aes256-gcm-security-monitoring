'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const web = path.resolve(__dirname, '..');
const app = fs.readFileSync(path.join(web, 'app.js'), 'utf8');
const server = fs.readFileSync(path.join(web, '..', 'server.py'), 'utf8');

const correlationStart = app.indexOf('if (task === "correlation")');
const correlationEnd = app.indexOf('if (task === "timeline")', correlationStart);
const correlation = app.slice(correlationStart, correlationEnd);
assert.match(correlation, /attackTimelineFocus\(attack\)/, 'recent-attack evidence must resolve the same current Timeline interval');
assert.match(correlation, /timelineFocus:[\s\S]*relatedEventIds/, 'recent-attack evidence must focus the attack bar and only related markers');
assert.match(correlation, /GCM_AUTH_FAIL \/ TAG[\s\S]*REPLAY_REJECT \/ REPLAY/, 'marker mapping must remain attack-type specific');
assert.match(app, /activateAiEvidence\(evidence, true\)/, 'attack focus must begin when the answer completes');
assert.match(app, /const authorizedUnlock = !locked && occ\.verdict === "PASS"[\s\S]*occ\.unlockSource === "QWE"[\s\S]*occ\.unlockSource === "OCC"/, 'the UI may open only for an explicit QWE or fresh OCC PASS authorization');
assert.match(app, /const interfaceLocked = locked \|\| !authorizedUnlock;[\s\S]*if \(interfaceLocked\)/, 'missing or malformed OCC state must stay locked');
assert.match(app, /const interfaceLocked = locked \|\| !authorizedUnlock;[\s\S]*occWasLocked = interfaceLocked;/, 'keyboard QWE must follow the actual displayed lock state');
assert.match(server, /assert occ\.snapshot\(\)\["locked"\][\s\S]*not occ\.ingest_line\(b"OPEN"/, 'server self-test must reject a malformed unlock line');

console.log('PASS recent attack Timeline focus and explicit OCC unlock gate');
