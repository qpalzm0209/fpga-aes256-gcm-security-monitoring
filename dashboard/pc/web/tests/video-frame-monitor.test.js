'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const app = fs.readFileSync(path.resolve(__dirname, '..', 'app.js'), 'utf8');

assert.match(app, /function startVideoFrameMonitor[\s\S]*requestVideoFrameCallback[\s\S]*videoLastFrameAt/, 'live capture needs a per-frame heartbeat');
assert.match(app, /video\.readyState >= 2[\s\S]*video\.currentTime !== lastMediaTime/, 'a media-time fallback must cover browsers without frame callbacks');
assert.match(app, /function stopStream\(\) \{\s*stopVideoFrameMonitor\(\)/, 'stopping capture must stop the monitor');
assert.match(app, /videoLastFrameAt = Date\.now\(\);\s*startVideoFrameMonitor\(stream\);/, 'the monitor must start with capture');

console.log('PASS video frame liveness monitor');
