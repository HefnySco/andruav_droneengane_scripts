#!/usr/bin/env node
/**
 * Bundle a DroneEngage Node.js server into a single minified file using esbuild.
 *
 * Produces <server_dir>/build/server.min.js — a minified, single-file bundle
 * of all JS source under src/. Non-JS assets (EJS views, CSS, SQL migrations)
 * stay in src/ and are referenced at runtime via the __dirname fixup plugin.
 *
 * Native modules (bcrypt, sqlite3, node-pty, better-sqlite3, mysql2, zeromq)
 * and the vendored droneengage_server_common package are kept external — they
 * must be installed in node_modules/ on the target.
 *
 * Prerequisites:
 *   npm install esbuild   # in any directory, or globally
 *
 * Usage:
 *   node build_server_bundle.js <server_dir>
 *
 * Examples:
 *   node build_server_bundle.js /path/to/droneengage_authenticator
 *   node build_server_bundle.js /path/to/droneengage_server
 *
 * After building, deploy to the target:
 *   1. Copy build/server.min.js to <target>/build/server.min.js
 *   2. Sync non-JS assets from src/ (exclude *.js, node_modules, ssl, .git)
 *   3. Remove all *.js files from <target>/src/ (keep node_modules)
 *   4. Point pm2 at build/server.min.js with --cwd <target>
 *
 * Key challenge: the source code uses __dirname from files at different directory
 * depths (src/, src/subdir/, src/subdir/subsubdir/). When bundled into a single
 * file, all __dirname references collapse to the bundle's directory.
 *
 * Solution: an esbuild plugin replaces each file's __dirname with a runtime
 * expression: require('path').resolve(__dirname, "<relative_path_to_original_dir>")
 * This way, __dirname in the bundle resolves to the original source directory
 * at runtime, preserving all path operations.
 */

const esbuild = require('esbuild');
const path = require('path');
const fs = require('fs');

const serverDir = process.argv[2];
if (!serverDir) {
  console.error('Usage: node build_server.js <server_dir>');
  process.exit(1);
}

const absServerDir = path.resolve(serverDir);
const srcDir = path.join(absServerDir, 'src');
const outDir = path.join(absServerDir, 'build');
const outFile = path.join(outDir, 'server.min.js');

// Native modules that cannot be bundled (must stay external)
const nativeExternals = [
  'bcrypt',
  'sqlite3',
  'node-pty',
  'zeromq',
  'better-sqlite3',
  'mysql2',
];

// Vendored/local modules that must stay external
const localExternals = [
  'droneengage_server_common',
];

// esbuild plugin: fix __dirname references in bundled code
const fixDirnamePlugin = {
  name: 'fix-dirname',
  setup(build) {
    // Only process files inside the server's src/ directory
    const srcDirNormalized = srcDir.replace(/\\/g, '/');

    build.onLoad({ filter: /\.js$/ }, async (args) => {
      const filePath = args.path.replace(/\\/g, '/');

      // Skip files outside src/ (node_modules, etc.)
      if (!filePath.startsWith(srcDirNormalized)) {
        return undefined; // let esbuild handle normally
      }

      const contents = await fs.promises.readFile(args.path, 'utf8');
      const sourceDir = path.dirname(args.path);

      // Compute relative path from the output directory to this file's source directory
      // The bundle will be at outDir/server.min.js, so __dirname = outDir at runtime
      let relPath = path.relative(outDir, sourceDir);
      if (relPath === '') relPath = '.';

      // Replace __dirname (as a word boundary) with a runtime resolution
      // require('path').resolve(__dirname, "<relPath>") resolves to the original source dir
      const fixed = contents.replace(
        /\b__dirname\b/g,
        `require('path').resolve(__dirname, ${JSON.stringify(relPath)})`
      );

      // Also fix __filename similarly
      const relFile = path.relative(outDir, args.path);
      const fixed2 = fixed.replace(
        /\b__filename\b/g,
        `require('path').resolve(__dirname, ${JSON.stringify(relFile)})`
      );

      return { contents: fixed2, loader: 'js' };
    });
  },
};

// Copy non-JS files from src/ to build/src/ (views, public, css, sql, etc.)
function copyNonJsAssets(srcBase, dstBase) {
  function walk(src, dst) {
    if (!fs.existsSync(src)) return;
    fs.mkdirSync(dst, { recursive: true });
    for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
      const srcPath = path.join(src, entry.name);
      const dstPath = path.join(dst, entry.name);
      if (entry.isDirectory()) {
        // Skip node_modules directories inside src/
        if (entry.name === 'node_modules') continue;
        walk(srcPath, dstPath);
      } else if (entry.name.endsWith('.js')) {
        // Skip JS files - they're bundled
        continue;
      } else {
        fs.copyFileSync(srcPath, dstPath);
      }
    }
  }
  walk(srcBase, dstBase);
}

async function main() {
  console.log(`Building ${absServerDir}...`);

  // Clean output directory
  if (fs.existsSync(outDir)) {
    fs.rmSync(outDir, { recursive: true, force: true });
  }
  fs.mkdirSync(outDir, { recursive: true });

  // Bundle with esbuild
  const result = await esbuild.build({
    entryPoints: [path.join(srcDir, 'server.js')],
    bundle: true,
    minify: true,
    format: 'cjs',
    platform: 'node',
    target: 'node22',
    outfile: outFile,
    sourcemap: false,
    sourcesContent: false,
    legalComments: 'none',
    keepNames: false,
    treeShaking: true,
    external: [...nativeExternals, ...localExternals],
    plugins: [fixDirnamePlugin],
    logLevel: 'warning',
    write: true,
  });

  if (result.warnings.length > 0) {
    console.log(`Warnings: ${result.warnings.length}`);
  }

  // Non-JS assets (views, public, css, sql) stay in src/ — the __dirname plugin
  // resolves to ../src/... which points to the original src/ directory at runtime.
  // No need to copy them anywhere.

  // Copy package.json (some code reads it via fs at runtime for version info)
  const pkgSrc = path.join(absServerDir, 'package.json');
  if (fs.existsSync(pkgSrc)) {
    fs.copyFileSync(pkgSrc, path.join(outDir, 'package.json'));
  }

  const stats = fs.statSync(outFile);
  console.log(`Bundle: ${outFile} (${(stats.size / 1024).toFixed(1)} KB)`);
  console.log('Non-JS assets remain in src/ (referenced via ../src/... at runtime)');
  console.log('Done.');
}

main().catch(err => {
  console.error('Build failed:', err);
  process.exit(1);
});
