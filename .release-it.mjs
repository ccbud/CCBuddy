import {
  createReleaseChangelogWriterOpts,
  RELEASE_CHANGELOG_PARSER_OPTS,
  RELEASE_CHANGELOG_TYPES,
} from "./scripts/release-it/changelog-writer.mjs";

export default {
  git: {
    commitMessage: "chore: release v${version}",
    tagName: "v${version}",
    tagAnnotation: "Release v${version}",
    // 修复原因：复制的发布脚本会自动推送当前 origin；CCbuddy 的发布地址应由操作者单独确认。
    push: false,
  },
  github: {
    release: false,
  },
  gitlab: {
    release: false,
  },
  npm: {
    publish: false,
  },
  plugins: {
    "@release-it/conventional-changelog": {
      preset: {
        name: "conventionalcommits",
        types: RELEASE_CHANGELOG_TYPES,
      },
      parserOpts: RELEASE_CHANGELOG_PARSER_OPTS,
      writerOpts: createReleaseChangelogWriterOpts(),
      infile: "CHANGELOG.md",
    },
  },
};
