'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const app = fs.readFileSync(path.resolve(__dirname, '..', 'app.js'), 'utf8');
assert.match(
  app,
  /function scheduleSessionEventLogRender\(\)\s*\{[\s\S]*?eventLogDrawer[\s\S]*?\.hidden\) return;/,
  'closed Event Log must not schedule a DOM rebuild for every incoming event',
);
const start = app.indexOf('function aggregateEventLog(');
assert.notEqual(start, -1, 'aggregateEventLog missing');
const bodyStart = app.indexOf(') {', start);
let depth = 0;
let source = '';
for (let index = bodyStart + 2; index < app.length; index += 1) {
  if (app[index] === '{') depth += 1;
  if (app[index] === '}') { depth -= 1; if (depth === 0) { source = app.slice(start, index + 1); break; } }
}
const { aggregateEventLog } = vm.runInNewContext(`${source}; ({ aggregateEventLog })`, {});

const events = [
  { timestamp: 10_100, category: 'security', source: 'RX', type: 'GCM_AUTH_FAIL' },
  { timestamp: 10_428, category: 'security', source: 'RX', type: 'GCM_AUTH_FAIL' },
  { timestamp: 10_999, category: 'security', source: 'RX', type: 'GCM_AUTH_FAIL' },
  { timestamp: 11_001, category: 'security', source: 'RX', type: 'GCM_AUTH_FAIL' },
  { timestamp: 11_050, category: 'attack', source: 'JETSON', type: 'REPLAY_START' },
];
const groups = aggregateEventLog(events);
assert.equal(groups.length, 3, 'packet-level security events share a source/type/one-second group');
assert.equal(groups[0].events.length, 3);
assert.equal(groups[1].events.length, 1);
assert.equal(groups[2].events.length, 1, 'attack lifecycle events remain individual');
console.log('PASS session event log aggregation');
