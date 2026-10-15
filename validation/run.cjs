const fs = require('node:fs');
const bridge = require('../_build/js/release/build/validation/bridge/bridge.js');
const evaluate = process.argv[2] === 'join' ? bridge.evaluate_join : bridge.evaluate;
for (const line of fs.readFileSync(0, 'utf8').trim().split('\n')) console.log(evaluate(Number(line)));
