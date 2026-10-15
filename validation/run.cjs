const fs = require('node:fs');
const bridge = require('../_build/js/release/build/validation/bridge/bridge.js');
const evaluate = ({join: bridge.evaluate_join, reduce: bridge.evaluate_reduce, scope_join: bridge.evaluate_scope_join, scope_reduce: bridge.evaluate_scope_reduce, feedback: bridge.evaluate_feedback})[process.argv[2]] || bridge.evaluate;
for (const line of fs.readFileSync(0, 'utf8').trim().split('\n')) console.log(evaluate(Number(line)));
