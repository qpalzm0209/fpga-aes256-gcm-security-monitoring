'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const web = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(web, 'index.html'), 'utf8');
const css = fs.readFileSync(path.join(web, 'styles.css'), 'utf8');
const app = fs.readFileSync(path.join(web, 'app.js'), 'utf8');
const server = fs.readFileSync(path.join(web, '..', 'server.py'), 'utf8');

function functionBody(source, name) {
  const start = source.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `missing ${name}`);
  const end = source.indexOf('\nfunction ', start + 1);
  return source.slice(start, end === -1 ? source.length : end);
}

assert.doesNotMatch(html, /mock-adapter\.js/, 'production UI must not load the prototype mock adapter');
assert.doesNotMatch(app, /prototypeAdapter|runFakeGemini|mock-adapter/, 'production UI must retain real integrations');
for (const endpoint of [
  '/api/state', '/api/occ/status', '/api/occ/emergency-unlock', '/api/occ/keyboard-lock',
  '/api/ai/status', '/api/ai/analyze', '/api/ai/chat',
]) assert.match(`${app}\n${server}`, new RegExp(endpoint.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')), `missing real endpoint ${endpoint}`);
assert.match(app, /setInterval\(pollState,\s*200\)/, 'state polling must remain 200 ms');
assert.match(app, /SpeechRecognition \|\| window\.webkitSpeechRecognition/, 'real browser speech input must remain');
assert.match(app, /\[data-ai-query\]/, 'approved quick prompts must be wired to the production adapter');
assert.match(app, /#aiQuestionForm button\[type='submit'\]/, 'busy state must address the real prototype submit button');
assert.doesNotMatch(app, /#aiStatus|#aiFooter|#aiSendButton|data-ai-task|data-mock-query/, 'production adapter must not dereference removed or mock IDs');
assert.match(app, /status\.configured[\s\S]*status\.model/, 'AI status must expose the real configured/model response');
assert.doesNotMatch(app, /LOCAL FAKE GEMINI|실제 API 연결 없음/, 'production UI must not expose fake runtime copy');
assert.match(app, /function taskFromQuestion\b/, 'typed and voice questions need a shared task inference path');
assert.match(app, /const QUICK_QUESTIONS\s*=\s*\{[\s\S]*performance:[\s\S]*timeline:/, 'all five quick prompts need real question mappings');
assert.match(app, /function currentEvidence\b/, 'focus metadata must derive from current production state');
assert.match(app, /function activateAiEvidence\b/, 'focus lifecycle must consume actual evidence');
assert.match(app, /speechRecognition\?\.stop\(\)/, 'voice completion must stop recognition rather than aborting it');
assert.match(app, /ctx\.font = "13px JetBrains"/, 'chart typography must match the prototype');
const submitBody = functionBody(app, 'submitAiChat');
assert.ok(submitBody.indexOf('clearAiFocus()') < submitBody.indexOf('appendAiMessage("user"'), 'a new typed/voice question must clear focus before appending');
assert.match(submitBody, /taskFromQuestion\(message\)/, 'typed/voice questions must infer their task');
const appendBody = functionBody(app, 'appendAiMessage');
assert.ok(appendBody.indexOf('const wasPinned') < appendBody.indexOf('append(message)'), 'chat pinning must be measured before appending');
const errorBody = app.slice(app.indexOf('speechRecognition.onerror'), app.indexOf('$$(', app.indexOf('speechRecognition.onerror')));
assert.match(errorBody, /setAiState\("IDLE"\)/, 'speech errors must restore the idle voice state');

for (const id of [
  'askAiButton', 'aiInteraction', 'aiAnalysisCard', 'aiState', 'aiCloseButton', 'aiChatHistory',
  'aiConversation', 'aiComposer', 'aiQuestionForm', 'aiQuestionInput', 'aiMicButton',
  'aiVoiceStage', 'aiVoiceListening', 'aiVoiceComplete', 'aiVoiceRetry', 'aiVoiceSubmit', 'aiClearFocus',
]) assert.match(html, new RegExp(`id="${id}"`), `missing ${id}`);
assert.match(html, /id="aiInteraction"[\s\S]*id="aiAnalysisCard"[\s\S]*id="aiChatHistory"[\s\S]*id="aiComposer"/, 'approved AI drawer structure must remain intact');
assert.match(html, /<b>✦<\/b> AI 질문/, 'the topbar sparkle button must match the approved prototype');
assert.match(html, />VALID FPS<\/dt>/, 'Page 01 must restore the approved VALID FPS label');
assert.equal((html.match(/data-ai-query=/g) || []).length, 5, 'approved five quick prompts must remain intact');
assert.match(html, /id="kpiAuthRejectCard"[\s\S]*GCM AUTH FAIL[\s\S]*id="kpiAuthRejectCount"[\s\S]*최근 1초[\s\S]*id="kpiAuthRejectDetail"/, 'GCM AUTH FAIL KPI must prioritize the recent one-second integer count');
assert.match(css, /\.kpi\.kpi-auth-reject strong\s*\{[^}]*font-size:\s*34px/s, 'AUTH recent-count value must remain the KPI primary metric');
assert.match(app, /function securityState\b[\s\S]*gcmAuthFailLast1s[\s\S]*gcmAuthFailTotal[\s\S]*replayRejectLast1s[\s\S]*processedTotal/, 'dashboard components must use one canonical security state');
assert.match(app, /GCM AUTH FAIL[\s\S]*kpiAuthRejectCard[\s\S]*tagDetector/s, 'AI authentication evidence must focus the KPI and TAG detector from the same source');
assert.match(app, /name === "tag" \? security\.gcmAuthFailTotal/, 'TAG detector must display the canonical GCM authentication-failure total');
assert.match(app, /timelineKnownRxEvents[\s\S]*detectorTypeFromEvent/s, 'timeline must retain actual RX security-event history independently from counters');
assert.doesNotMatch(app, /timelinePreviousTotals/, 'timeline must not manufacture events from cumulative detector counters');
assert.doesNotMatch(html, /AUTH \/ REPLAY TOTAL/, 'receiver health must not duplicate attack counters');
assert.match(html, /GCM AUTH FAIL[\s\S]*최근 1초[\s\S]*누적 —건/, 'GCM card must prioritize a one-second count then cumulative total');
assert.match(html, /REPLAY REJECT[\s\S]*최근 1초[\s\S]*누적 —건/, 'replay card must use the same explicit count semantics');
assert.match(server, /return 0 if baseline is None/, 'the first valid counter sample must render as zero, not a dash');
assert.match(server, /_auth_fail_samples[\s\S]*_replay_reject_samples[\s\S]*gcm_auth_fail_last_1s[\s\S]*replay_reject_last_1s[\s\S]*processed_unit/s, 'backend must publish one canonical security and RX-health state');

assert.match(css, /--ai-focus:\s*#B768FF/i, 'approved purple focus token missing');
const prototypeCssMarker = '/* Gemini prototype refinements. The original Page01/Page02 structure remains unchanged. */';
assert.notEqual(css.indexOf(prototypeCssMarker), -1, 'approved prototype styling marker missing');
for (const requiredRule of ['.ai-drawer-panel', '.ai-chat-history', '.ai-voice-primary', '.ai-question-form']) {
  assert.match(css, new RegExp(requiredRule.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')), `approved drawer rule missing: ${requiredRule}`);
}
assert.match(css, /\.workspace\.ai-drawer-open\s*\{[^}]*clamp\(380px,\s*23vw,\s*440px\)/s, 'drawer must be fixed at 380–440px');
assert.match(css, /\.ai-drawer-panel\s*\{[^}]*grid-template-rows:\s*auto\s+minmax\(0,\s*1fr\)\s+auto/s, 'drawer must use fixed header/chat/composer rows');
assert.match(css, /\.ai-chat-history\s*\{[^}]*overflow-y:\s*auto/s, 'chat history must be the vertical scroll region');
assert.match(css, /#analysisPage\.ai-focus-mode \.ai-evidence-target\s*\{[^}]*border:\s*2px solid var\(--ai-focus\)/s, 'focused cards require purple evidence styling');
assert.match(css, /\.ai-voice-primary\s*\{[^}]*width:\s*60px[^}]*height:\s*60px/s, 'voice-first composer requires a 60px mic');
assert.match(html, /id="kpiAuthRejectRate"[\s\S]*id="kpiReplayRate"/, 'both security KPIs must retain an explicit rate line');
assert.match(html, /최근 판정[\s\S]*id="correlationText"[\s\S]*Frame \/ Packet 기준/, 'correlation must show one readable current verdict and its real comparison basis');
assert.doesNotMatch(html, /누적 일치|누적 불일치/, 'correlation must not invent cumulative match statistics');
assert.match(server, /network_loss_total[\s\S]*queue_overrun_total/, 'backend must publish session cumulative RX health state');
assert.match(html, /id="eventLogButton"[\s\S]*id="eventLogDrawer"[\s\S]*id="eventLogList"/, 'session event history must be a left drawer, not a dashboard card');
assert.match(css, /\.page-tabs\s*\{[^}]*left:\s*50%[^}]*translateX\(-50%\)/s, 'page navigation must use the actual header center');
assert.match(css, /\.event-log-drawer\s*\{[^}]*position:\s*fixed/s, 'event log must overlay rather than resize the dashboard');
assert.match(app, /const sessionEvents = \[\][\s\S]*function getSessionEvents[\s\S]*function renderSessionEventLog/s, 'session events must outlive the 60-second timeline window');
assert.match(app, /function aggregateEventLog[\s\S]*event\.category === "security"[\s\S]*current\.second === second/s, 'packet-level security events must be aggregated by source/type/one-second window');
assert.match(app, /function scheduleSessionEventLogRender[\s\S]*}, 200\)/s, 'event log rendering must be sampled instead of rendering every packet');
assert.match(app, /function canonicalVideoState[\s\S]*deviceConnected[\s\S]*streamActive[\s\S]*lastFrameAt/s, 'AI context must use canonical video state');
assert.match(app, /function buildCanonicalSystemState[\s\S]*video:\s*syncCanonicalVideoState\(\)[\s\S]*function aiContext[\s\S]*buildCanonicalSystemState\(state\)/s, 'AI must receive the same video state as the live capture UI');
assert.match(server, /context\.video[\s\S]*VIDEO LIVE[\s\S]*sessionEvents/s, 'Gemini instructions must distinguish canonical video state and session history');
assert.match(app, /aiMessages\.push\(\{ role, text, timestamp \}\)[\s\S]*toLocaleTimeString\("en-GB"/s, 'chat message timestamps must be created once and retained');

console.log('PASS production dashboard prototype-accurate drawer and real API contract');
