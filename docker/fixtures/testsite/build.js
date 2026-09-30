// Stand-in frontend build for the docker test harness: no registry
// dependencies (local-dep is a file: dependency), just proves which node
// version and NODE_ENV the deploy ran it under, and that `npm ci` really
// installed node_modules.
const fs = require('fs');
const dep = require('local-dep');

const MARKER = 'fe-v1';

fs.mkdirSync('web/dist', { recursive: true });
fs.writeFileSync(
    'web/dist/build.txt',
    `BUILD=${MARKER} NODE=${process.version} NODE_ENV=${process.env.NODE_ENV || ''} DEP=${dep}\n`
);
