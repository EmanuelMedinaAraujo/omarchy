#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const panelSource = fs.readFileSync(root + '/shell/plugins/agents/Panel.qml', 'utf8')

const signInFunctions = ['supportsSignIn', 'needsSignIn', 'otherTrouble'].map(name => {
  const match = panelSource.match(new RegExp('function ' + name + '\\([^]*?\\n  \\}'))
  return match ? match[0] : ''
}).join('\n')
const signIn = new Function('addProviders', signInFunctions + '\nreturn {needsSignIn, otherTrouble}')(
  [{providerId: 'claude'}, {providerId: 'codex'}, {providerId: 'grok'}]
)
for (const id of ['claude', 'codex', 'grok'])
  assert(signIn.needsSignIn({providerId: id, usageStatusText: 'Sign-in expired'}), id + ' keeps its sign-in link')
assert(signIn.needsSignIn({usageStatusText: 'Sign-in expired'}), 'account rows keep their sign-in link')
for (const status of ['Sign-in expired', 'Waiting for auth']) {
  assert(!signIn.needsSignIn({providerId: 'agy', usageStatusText: status}), 'an agent the panel cannot sign in gets no link for ' + status)
  assert(signIn.otherTrouble({providerId: 'agy', usageStatusText: status}) === status, 'an agent the panel cannot sign in still shows ' + status)
}

// A reworded collector line would silently fall back to English, so every
// fixed help line the collectors cache must still be one the panel maps.
for (const name of ['claude', 'codex', 'grok', 'fireworks']) {
  const collector = fs.readFileSync(root + '/bin/omarchy-agent-usage-' + name, 'utf8')
  const help = collector.match(/^AUTH_HELP = "([^"]+)"$/m)
  assert(help && panelSource.includes('case ' + JSON.stringify(help[1]) + ':'), name + ' auth help is translated in the panel')
}
JS

# The panel reads a window out of a label, and that guess cannot survive a
# model name — "Opus 5 (1M context)" parses as a one-minute window. A collector
# that states the title outright is taken at its word.
run_node_test <<'JS'
const fs = require('fs')
const source = fs.readFileSync(root + '/shell/plugins/agents/Panel.qml', 'utf8')
const panelRoot = { nowMs: Date.now() }
const start = source.indexOf('function windowIsLong')
const end = source.indexOf('// The window that decides')
assert(start > 0 && end > start, 'agents panel exposes its limit-window helpers')
eval(source.slice(start, end).replaceAll('root.nowMs', 'panelRoot.nowMs'))
eval(source.slice(source.indexOf('function needsSignIn'), source.indexOf('// Sign an account')))

const paused = { usageStatusText: 'Limits paused', limits: [] }
assertEqual(pausedWithoutLimits(paused), true, 'paused usage without a cache shows a recovery placeholder')
assertEqual(otherTrouble(paused), '', 'paused usage never puts the confusing status in the header')
assertEqual(pausedWithoutLimits({ ...paused, limits: [{ label: 'Session (5-hour)', percent: 0, resetsAt: '' }] }), false, 'cached usage replaces the recovery placeholder')
assertEqual(pausedWithoutLimits({ usageStatusText: 'Sign-in expired', limits: [] }), false, 'expired sign-ins retain their sign-in action')
assertEqual(pausedWithoutLimits(null), false, 'missing records do not show a paused-usage placeholder')

assertDeepEqual(
  limitWindows({ limits: [
    { label: 'Session (5-hour)', percent: 0.78, resetsAt: '' },
    { label: 'Opus 5 (1M context) Weekly', title: 'Opus 5 (1M context) Weekly', percent: 0.42, resetsAt: '' }
  ] }),
  [
    { title: 'Session', percent: 0.78, resetAt: '' },
    { title: 'Opus 5 (1M context) Weekly', percent: 0.42, resetAt: '' }
  ],
  'agents panel titles a limit off the collector when it states one'
)

assertDeepEqual(
  limitWindows({ limits: [{ label: 'Weekly (7-day)', percent: 0.12, resetsAt: '' }] }),
  [{ title: 'Weekly', percent: 0.12, resetAt: '' }],
  'agents panel still reads a window out of a label that carries no title'
)

const resetAt = new Date(panelRoot.nowMs + 1000).toISOString()
const measured = { limits: [{ label: 'Session (5-hour)', percent: 0.78, resetsAt: resetAt }] }
assertEqual(limitWindows(measured)[0].percent, 0.78, 'usage remains until the reset time')
panelRoot.nowMs += 1000
assertDeepEqual(limitWindows(measured), [{ title: 'Session', percent: 0, resetAt: '' }], 'usage resets at the deadline while the panel stays open')
assertEqual(measured.limits[0].percent, 0.78, 'display reset leaves the measured record intact')

// The bar icon has to drop its alarm at that deadline with the panel closed,
// so the panel finds the soonest reset still ahead, then moves its clock and
// fetches the limits again. One timer waits the whole way, short of the
// longest interval a timer can hold.
const tickNow = Date.parse('2026-10-11T12:00:00Z')
const tickProviders = [
  { limits: [
    { label: 'Session (5-hour)', percent: 0.95, resetsAt: '2026-10-11T11:00:00Z' },
    { label: 'Weekly (7-day)', percent: 0.4, resetsAt: '2026-10-14T00:00:00Z' }
  ] },
  { limits: [{ label: 'Session (5-hour)', percent: 0.2, resetsAt: '2026-10-11T13:30:00Z' }, { label: 'Weekly (7-day)', percent: 0.1, resetsAt: '' }] },
  { limits: [] },
  {}
]
assertEqual(nextResetMs(tickProviders, tickNow), Date.parse('2026-10-11T13:30:00Z'), 'the next reset is the soonest one still ahead, across every agent')
assertEqual(nextResetMs(tickProviders, Date.parse('2026-10-14T00:00:00Z')), 0, 'no reset is pending once every window has rolled over')
assertEqual(nextResetMs([], tickNow), 0, 'no agents, no reset to wait for')
assertEqual(resetTickDelay(tickNow + 5000, tickNow), 5000, 'a reset a few seconds off is waited out exactly')
assertEqual(resetTickDelay(tickNow + 18000000, tickNow), 18000000, 'a reset hours off is waited out in one go, with no wake in between')
assertEqual(resetTickDelay(tickNow + 30 * 86400000, tickNow), 2147483647, 'a reset past the longest interval a timer can hold is waited for in stages')
assertEqual(resetTickDelay(tickNow - 7200000, tickNow), 0, 'a reset already past is due at once')

// A model's weekly allowance rides under the Weekly row; one whose window has
// no row of its own keeps a row.
assertDeepEqual(
  displayWindows({ limits: [
    { label: 'Session (5-hour)', percent: 0.94, resetsAt: '' },
    { label: 'Weekly (7-day)', percent: 0.25, resetsAt: 'w' },
    { label: 'Fable Weekly', title: 'Fable Weekly', percent: 0.09, resetsAt: 'w' },
    { label: 'Opus Monthly', title: 'Opus Monthly', percent: 0.5, resetsAt: '' }
  ] }),
  [
    { title: 'Session', percent: 0.94, resetAt: '', scoped: [] },
    { title: 'Weekly', percent: 0.25, resetAt: 'w', scoped: [{ title: 'Fable', percent: 0.09, resetAt: 'w' }] },
    { title: 'Opus Monthly', percent: 0.5, resetAt: '', scoped: [] }
  ],
  'agents panel shows a model-scoped window under the window it runs on'
)
JS

# The bar clock, reset timer, opening and resume each run the real panel
# handlers against a moving wall clock, so a missed or doubled fetch shows.
run_node_test <<'JS'
const fs = require('fs')
const vm = require('vm')
const source = fs.readFileSync(root + '/shell/plugins/agents/Panel.qml', 'utf8')
function panelFunction(name) {
  const start = source.indexOf('  function ' + name + '(')
  assert(start >= 0, 'panel exposes ' + name)
  return source.slice(start, source.indexOf('\n  }', start) + 4)
}
const dueBody = source.match(/readonly property double resetDueMs: \{([\s\S]*?)\n  \}/)[1]
const tickBody = source.match(/interval: 30000[\s\S]*?onTriggered: ([^\n]+)/)[1]
const timerBody = source.match(/id: resetTimer\n\s+onTriggered: ([^\n]+)/)[1]
const resumeBody = source.match(/function onResumed\(\) \{ ([^\n]+) \}/)[1]
const openStart = source.indexOf('onOpenedChanged: if (opened) {')
const openBody = source.slice(openStart + 'onOpenedChanged: '.length, source.indexOf('\n  }', openStart) + 4)
const helpers = ['nextResetMs', 'resetTickDelay', 'armResetTimer', 'advanceClock'].map(panelFunction).join('\n')
const startTime = Date.parse('2026-10-11T12:00:00Z')
const firstReset = Date.parse('2026-10-11T13:30:00Z')
const secondReset = Date.parse('2026-10-14T00:00:00Z')

function panel(resets = [firstReset, secondReset]) {
  let wallClock = startTime
  let clock = wallClock
  let fetches = 0
  const timer = {
    interval: 0, running: false,
    restart() { this.running = true },
    stop() { this.running = false }
  }
  const model = {
    Date: class extends Date { static now() { return wallClock } },
    providers: [{ limits: resets.map(reset => ({ resetsAt: new Date(reset).toISOString() })) }],
    usage: { refreshLimits() { fetches++ } },
    resetTimer: timer,
    opened: true, addStage: '', panelFlick: null,
    resetKeys() {}, Qt: { callLater() {} },
    get nowMs() { return clock },
    set nowMs(value) {
      const due = this.resetDueMs
      clock = value
      // Model QML's immediate binding update: advancing nowMs can replace the
      // deadline and cancel the previous timer before its callback is handled.
      if (this.resetDueMs !== due) this.armResetTimer()
    }
  }
  model.root = model
  vm.createContext(model)
  vm.runInContext(helpers + '\nfunction dueBinding() {' + dueBody + '\n}', model)
  Object.defineProperty(model, 'resetDueMs', { get: () => model.dueBinding() })
  model.armResetTimer()
  return {
    model, timer,
    at(value) { wallClock = value },
    fire(body) { vm.runInContext(body, model) },
    get fetches() { return fetches }
  }
}

let p = panel()
p.at(firstReset + 3001)
p.fire(tickBody)
assertEqual(p.fetches, 1, 'a 30-second tick handled before an overdue reset timer still fetches that window')
assertEqual(p.model.nowMs, firstReset + 3001, 'the clock tick advances the clock read by the bar')
assertEqual(p.model.resetDueMs, secondReset + 3000, 'the tick rearms for the next actual window')
p.fire(timerBody)
assertEqual(p.fetches, 1, 'a queued reset callback after the clock tick does not fetch twice')

p = panel()
p.at(firstReset + 3000)
p.fire(timerBody)
p.fire(tickBody)
assertEqual(p.fetches, 1, 'reset timer before clock tick also fetches once at the exact deadline')

p = panel()
p.at(firstReset + 3001)
p.fire(openBody)
assertEqual(p.fetches, 1, 'opening after a deadline requests one refresh')
p = panel()
p.fire(openBody)
assertEqual(p.fetches, 1, 'opening before a deadline still fetches fresh limits once')

p = panel()
p.at(secondReset + 10000)
p.fire(resumeBody)
assertEqual(p.fetches, 1, 'resume past several resets fetches all limits once')
assertEqual(p.model.resetDueMs, 0, 'resume past the final reset leaves no pending deadline')
assertEqual(p.timer.running, false, 'resume past the final reset stops the timer')
p.fire(resumeBody)
assertEqual(p.fetches, 1, 'a repeated resume with no pending reset does not fetch')

p = panel()
p.at(firstReset + 2000)
p.fire(resumeBody)
assertEqual(p.fetches, 0, 'resume inside the provider grace period does not fetch early')
assertEqual(p.model.nowMs, firstReset + 2000, 'resume inside the grace period still updates the bar clock')
assertEqual(p.timer.interval, 1000, 'resume inside the grace period waits only the remaining second')
p.at(firstReset + 3000)
p.fire(timerBody)
assertEqual(p.fetches, 1, 'the remaining grace timer fetches at its deadline')

p = panel([startTime + 30 * 86400000])
assertEqual(p.timer.interval, 2147483647, 'a distant reset initially waits the maximum timer interval')
p.at(startTime + 2147483647)
p.timer.running = false
p.fire(timerBody)
assertEqual(p.fetches, 0, 'a capped wait does not fetch before the reset')
assertEqual(p.timer.running, true, 'a capped wait rearms even when the deadline binding stays unchanged')
assertEqual(p.timer.interval, 30 * 86400000 + 3000 - 2147483647, 'a capped wait uses its remaining wall-clock duration')

p = panel()
p.at(startTime - 10000)
p.fire(timerBody)
assertEqual(p.fetches, 0, 'a backward clock adjustment does not fetch early')
assertEqual(p.timer.interval, firstReset + 3000 - startTime + 10000, 'a backward clock adjustment rearms against the wall clock')

p = panel([])
p.at(startTime + 10000)
p.fire(tickBody)
p.fire(resumeBody)
assertEqual(p.fetches, 0, 'clock ticks and resume with no reset do not fetch')
p.fire(openBody)
assertEqual(p.fetches, 1, 'opening with no reset still fetches fresh limits')
JS
