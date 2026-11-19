'use strict';
const { run } = require('./run');

process.exitCode = run('post.sh', process.env);
