'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const web = path.resolve(__dirname, '..');
const app = fs.readFileSync(path.join(web, 'app.js'), 'utf8');
const server = fs.readFileSync(path.join(web, '..', 'server.py'), 'utf8');

function bodyOf(name) {
  const start = app.indexOf(`function ${name}(`) >= 0
    ? app.indexOf(`function ${name}(`) : app.indexOf(`async function ${name}(`);
  assert.notEqual(start, -1, `missing ${name}`);
  const end = app.indexOf('\nfunction ', start + 1);
  return app.slice(start, end === -1 ? app.length : end);
}

const request = bodyOf('requestAi');
assert.match(request, /const analysisSnapshot = aiContext/, 'request must capture one analysis snapshot before Gemini runs');
assert.match(request, /const evidence = currentEvidence\(evidenceTask, latestState, analysisAt\)/, 'evidence must be captured from that request-time state');
assert.match(request, /analysisSnapshot\.answerEvidence/, 'the Gemini prompt must receive the exact evidence set');
assert.match(request, /completeAnswerWithEvidence\(result\.text \|\| "EMPTY RESPONSE", evidence\)/, 'missing evidence mentions must be completed from the same snapshot');
assert.match(request, /activateAiEvidence\(evidence, true\)/, 'completed answers must focus automatically without a click');
assert.doesNotMatch(request.slice(0, request.indexOf('try {')), /clearAiFocus\(\)/, 'old focus must remain while a new answer is pending');
assert.match(app, /function refocusAiEvidence\b[\s\S]*aiAllEvidence/, 'clicking evidence must re-focus instead of replacing the answer focus');
assert.match(app, /button\.addEventListener\("click", \(\) => refocusAiEvidence\(item\)\)/, 'metadata links must use the re-focus action');
assert.match(app, /function selectAutoFocusEvidence\b[\s\S]*slice\(0, 5\)/, 'automatic focus must remain limited to core evidence');
assert.match(server, /context\.answerEvidence[\s\S]*0도 관측값/, 'Gemini must be told to cite the supplied values, including zero');

console.log('PASS Gemini answer, evidence snapshot, and automatic focus lifecycle');
