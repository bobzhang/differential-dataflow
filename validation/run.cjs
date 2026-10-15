const fs = require('node:fs');
const bridge = require('../_build/js/release/build/validation/bridge/bridge.js');
const evaluate = ({join: bridge.evaluate_join, reduce: bridge.evaluate_reduce, scope_join: bridge.evaluate_scope_join, scope_reduce: bridge.evaluate_scope_reduce, feedback: bridge.evaluate_feedback, iteration: bridge.evaluate_iteration, arrangement: bridge.evaluate_arrangement, upsert: bridge.evaluate_upsert, replay: bridge.evaluate_replay, group_join: bridge.evaluate_group_join})[process.argv[2]] || bridge.evaluate;
for (const line of fs.readFileSync(0, 'utf8').trim().split('\n')) console.log(evaluate(Number(line)));
