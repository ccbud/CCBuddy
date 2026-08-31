'use strict';

// Serves the legacy renderer exactly as Tauri packages it: renderer assets at `/` and
// the split localization catalogs under `/shared`. The latter live in src/shared in the
// source tree and are copied beside the renderer only during a Tauri bundle build.
const fs = require('fs');
const http = require('http');
const path = require('path');

const SOURCE_ROOT = path.join(__dirname, '..', 'src');
const RENDERER_ROOT = path.join(SOURCE_ROOT, 'renderer');
const MIME = {
  '.css': 'text/css',
  '.html': 'text/html',
  '.js': 'text/javascript',
  '.json': 'application/json',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
};

function resolveRequestPath(requestURL) {
  const pathname = decodeURIComponent(new URL(requestURL, 'http://127.0.0.1').pathname);
  const relative = pathname.replace(/^\/+/, '');
  const root = relative.startsWith('shared/') ? SOURCE_ROOT : RENDERER_ROOT;
  const file = path.resolve(root, relative);
  if (file !== root && !file.startsWith(root + path.sep)) return null;
  return file;
}

function createRendererFixtureServer() {
  return http.createServer((request, response) => {
    const file = resolveRequestPath(request.url || '/');
    if (!file) {
      response.writeHead(400);
      response.end('400');
      return;
    }
    fs.readFile(file, (error, contents) => {
      if (error) {
        response.writeHead(error.code === 'ENOENT' ? 404 : 500);
        response.end(error.code === 'ENOENT' ? '404' : '500');
        return;
      }
      response.writeHead(200, {
        'cache-control': 'no-store',
        'content-type': MIME[path.extname(file)] || 'application/octet-stream',
      });
      response.end(contents);
    });
  });
}

if (require.main === module) {
  const port = Number(process.env.CCBUD_RENDERER_PORT || 4599);
  createRendererFixtureServer().listen(port, '127.0.0.1', () => {
    process.stdout.write(`Renderer fixture server: http://127.0.0.1:${port}/\n`);
  });
}

module.exports = { createRendererFixtureServer };
