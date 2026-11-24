#!/usr/bin/env node
/**
 * Compatibility launcher for the canonical Python evidence analyzer.
 *
 * Usage:
 *   node scripts/metrics/analyze-control-loop-latency.js docs/evidence/<run-id>
 */

const path = require('path');
const { spawnSync } = require('child_process');

const python = process.env.PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
const analyzer = path.join(__dirname, 'analyze-control-loop-latency.py');
const result = spawnSync(python, [analyzer, ...process.argv.slice(2)], { stdio: 'inherit' });

if (result.error) {
  console.error(`Could not run Python analyzer with "${python}": ${result.error.message}`);
  process.exit(1);
}

process.exit(result.status === null ? 1 : result.status);
