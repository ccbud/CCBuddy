'use strict';

// ccbud i18n manifest — which part files make up each language (see index.js for the
// Node-side merged dictionary). The renderer injects ONLY the active language's parts.
(function (root) {
  var api = {
    LANGS: ["en","zh","zh-TW","ja","ko"],
    LOCALE_TAG: {"en":"en-US","zh":"zh-CN","zh-TW":"zh-TW","ja":"ja-JP","ko":"ko-KR"},
    PARTS: {"en":["en-app.js","en-conv.js","en-ops.js","en-settings.js","en-skills.js"],"zh":["zh-app.js","zh-conv.js","zh-ops.js","zh-settings.js","zh-skills.js"],"zh-TW":["zh-TW-app.js","zh-TW-conv.js","zh-TW-ops.js","zh-TW-settings.js","zh-TW-skills.js"],"ja":["ja-app.js","ja-conv.js","ja-ops.js","ja-settings.js","ja-skills.js"],"ko":["ko-app.js","ko-conv.js","ko-ops.js","ko-settings.js","ko-skills.js"]},
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (root) root.ccbudI18nParts = api;
})(typeof window !== 'undefined' ? window : null);
