'use strict';

/*
 * ccbud i18n dictionary index — en/zh/zh-TW/ja/ko split per language + domain so no
 * source file exceeds the 220-line limit and the renderer can load ONLY the active
 * language at startup (cold-start: ~1/5 of the old single-file dictionary).
 * Node consumers (tests) keep the legacy { DICT, LANGS, LOCALE_TAG } API via require().
 * 'en' is the canonical key set (test/i18n.test.js enforces every locale matches it).
 */
var LANGS = ["en","zh","zh-TW","ja","ko"];
var LOCALE_TAG = {"en":"en-US","zh":"zh-CN","zh-TW":"zh-TW","ja":"ja-JP","ko":"ko-KR"};
// Per-language part files, in load order. The renderer's ensureLang() reads this too.
var PARTS = {
  'en': [
    'en-app.js',
    'en-conv.js',
    'en-ops.js',
    'en-settings.js',
    'en-skills.js'
  ],
  'zh': [
    'zh-app.js',
    'zh-conv.js',
    'zh-ops.js',
    'zh-settings.js',
    'zh-skills.js'
  ],
  'zh-TW': [
    'zh-TW-app.js',
    'zh-TW-conv.js',
    'zh-TW-ops.js',
    'zh-TW-settings.js',
    'zh-TW-skills.js'
  ],
  'ja': [
    'ja-app.js',
    'ja-conv.js',
    'ja-ops.js',
    'ja-settings.js',
    'ja-skills.js'
  ],
  'ko': [
    'ko-app.js',
    'ko-conv.js',
    'ko-ops.js',
    'ko-settings.js',
    'ko-skills.js'
  ]
};

function mergedDict(lang) {
  var out = {};
  PARTS[lang].forEach(function (f) {
    var part = require('./' + f);
    Object.keys(part).forEach(function (k) { out[k] = part[k]; });
  });
  return out;
}

var DICT = {};
LANGS.forEach(function (l) { DICT[l] = mergedDict(l); });

module.exports = { DICT: DICT, LANGS: LANGS, LOCALE_TAG: LOCALE_TAG, PARTS: PARTS };
