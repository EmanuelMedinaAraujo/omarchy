#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const vm = require('vm')
const source = fs.readFileSync(root + '/shell/plugins/agents/Panel.qml', 'utf8')
function panelFunction(name) {
  const start = source.indexOf('  function ' + name + '(')
  assert(start >= 0, 'panel exposes ' + name)
  return source.slice(start, source.indexOf('\n  }', start) + 4)
}

let wallClock = 10000
let clock = wallClock
let fetches = 0
let armedFor = 0
let resets = [20000, 100000]
const model = {
  Date: { now: () => wallClock },
  usage: { refreshLimits() { fetches++ } },
  armResetTimer() { armedFor = model.resetDueMs },
  get resetDueMs() { return resets.find(reset => reset > clock) || 0 },
  get nowMs() { return clock },
  set nowMs(value) {
    const due = this.resetDueMs
    clock = value
    // QML re-evaluates the due binding and restarts the timer immediately.
    if (this.resetDueMs !== due) this.armResetTimer()
  }
}
model.root = model
vm.createContext(model)
vm.runInContext(panelFunction('resetElapsed'), model)

wallClock = 30000
model.resetElapsed()
assertEqual(fetches, 1, 'resume after a reset fetches fresh limits once')
assertEqual(clock, wallClock, 'resume advances the clock read by the bar')
assertEqual(armedFor, 100000, 'resume arms the next reset after a missed window')
model.resetElapsed()
assertEqual(fetches, 1, 'a repeated resume does not fetch the same reset twice')

wallClock = 40000
model.resetElapsed()
assertEqual(fetches, 1, 'resume before a reset does not fetch early')
assertEqual(armedFor, 100000, 'resume before a reset rearms its wall-clock deadline')

wallClock = 200000
model.resetElapsed()
assertEqual(fetches, 2, 'resume past the final reset fetches once')
assertEqual(armedFor, 0, 'resume past the final reset leaves no timer armed')
model.resetElapsed()
assertEqual(fetches, 2, 'resume with no pending reset does not fetch')

assert(/firstPartyServiceFor\("omarchy\.idle"\)/.test(source), 'the panel subscribes to the non-authentication idle service')
assert(/function onResumed\(\) \{ root\.resetElapsed\(\) \}/.test(source), 'resume invokes the tested catch-up handler')
assert(!/firstPartyServiceFor\("omarchy\.lock"\)/.test(source), 'resume does not depend on the authentication service')
JS
