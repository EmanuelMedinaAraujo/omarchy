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
assert(/onResetDueMsChanged: armResetTimer\(\)/.test(source), 'a new soonest reset rearms the timer')
assertEqual(resetTickDelay(tickNow + 5000, tickNow), 5000, 'a reset a few seconds off is waited out exactly')
assertEqual(resetTickDelay(tickNow + 18000000, tickNow), 18000000, 'a reset hours off is waited out in one go, with no wake in between')
assertEqual(resetTickDelay(tickNow + 30 * 86400000, tickNow), 2147483647, 'a reset past the longest interval a timer can hold is waited for in stages')
assertEqual(resetTickDelay(tickNow - 7200000, tickNow), 0, 'a reset already past is due at once')
assert(!/id: resetTimer\n\s+repeat: true/.test(source), 'the reset timer is single-shot, not a recurring wake')
assert(/nextResetMs\(providers, nowMs - 3000\)/.test(source), 'the reset deadline includes the three-second provider grace period')

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
