const fs = require('node:fs');
const {evaluate} = require('../_build/js/release/build/validation/bridge/bridge.js');
for (const line of fs.readFileSync(0, 'utf8').trim().split('\n')) console.log(evaluate(Number(line)));
