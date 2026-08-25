'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const app = fs.readFileSync(path.resolve(__dirname, '..', 'app.js'), 'utf8');

function sourceOf(name) {
  const start = app.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `missing ${name}`);
  // The first brace can belong to a destructured parameter. Start at the
  // function body brace instead, so the extracted program remains valid.
  const bodyStart = app.indexOf(') {', start);
  assert.notEqual(bodyStart, -1, `missing body for ${name}`);
  let depth = 0;
  for (let index = bodyStart + 2; index < app.length; index += 1) {
    if (app[index] === '{') depth += 1;
    if (app[index] === '}') {
      depth -= 1;
      if (depth === 0) return app.slice(start, index + 1);
    }
  }
  throw new Error(`unterminated ${name}`);
}

function fixture() {
  let clock = 1_000;
  const context = {
    Date: { now: () => clock },
    globalThis: {},
    console,
  };
  const code = [
    'const timelineSegments = []; const timelineEvents = []; const timelineKnownRxEvents = new Map();',
    'let timelineEventId = 0; let timelinePreviousAttack = null; let timelinePreviousRxOnline = false;',
    'function sessionEventFromTimeline() { return null; } function pushSessionEvent() {}',
    sourceOf('createTimelineEvent'), sourceOf('pushTimelineEvent'),
    sourceOf('latestOpenTimelineSegment'), sourceOf('startTimelineAttack'),
    sourceOf('stopTimelineAttack'), sourceOf('keepTimelineAttackRunning'),
    'function detectorTypeFromEvent() { return null; } function finiteValue() { return null; } function valueFrom() { return null; } function pruneTimeline() {}',
    sourceOf('updateSecurityTimeline'),
    'globalThis.timelineTest = { timelineSegments, timelineEvents, updateSecurityTimeline };',
  ].join('\n');
  vm.runInNewContext(code, context);
  return {
    data: context.globalThis.timelineTest,
    tick(milliseconds) { clock += milliseconds; },
    update(attack) { context.globalThis.timelineTest.updateSecurityTimeline({ events: [] }, {}, attack, false, {}); },
  };
}

const running = (active = true, connected = true) => ({
  active, connected, mode: 'replay', rate: 10, runtimeMs: 0,
});

// CASE 1: RUNNING with recent injection starts an ACTIVE interval.
const first = fixture();
first.update(running());
assert.equal(first.data.timelineSegments.length, 1);
assert.equal(first.data.timelineSegments[0].end, null);
assert.equal(first.data.timelineSegments[0].interruptedAt, null);

// CASE 2: a five-second event gap does not close a controller-RUNNING interval.
first.tick(5_000);
first.update(running());
assert.equal(first.data.timelineSegments.length, 1);
assert.equal(first.data.timelineSegments[0].interruptedAt, null);
assert.equal(first.data.timelineSegments[0].end, null);

// CASE 3: an explicit controller stop is the only normal completion path.
first.tick(200);
first.update(running(false));
assert.notEqual(first.data.timelineSegments[0].end, null);

// CASE 4: a true observer heartbeat loss closes as interrupted, but a later
// RUNNING heartbeat resumes the same interval instead of leaving it stale.
const fourth = fixture();
fourth.update(running());
fourth.tick(2_000);
fourth.update(running(false, false));
assert.notEqual(fourth.data.timelineSegments[0].interruptedAt, null);
fourth.tick(200);
fourth.update(running());
assert.equal(fourth.data.timelineSegments.length, 1);
assert.equal(fourth.data.timelineSegments[0].interruptedAt, null);

console.log('PASS attack timeline lifecycle: running gap, stop, heartbeat recovery');
