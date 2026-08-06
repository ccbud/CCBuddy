/* 会话 view markup — injected on first switch (kept off the cold-start path). */
export const CONVERSATIONS_HTML = `
        <section id="view-conversations" data-clarity-mask="true" class="panel-full hidden flex-grow min-h-0 w-full overflow-hidden flex animate-[panelIn_0.28s_ease-[cubic-bezier(0.23,1,0.32,1)]]">
          <div class="conv-layout flex w-full h-full overflow-hidden">
            <aside class="conv-sidebar group/conv-sidebar border-r border-border-custom flex flex-col shrink-0 overflow-hidden [&.collapsed]:overflow-visible">
              <div class="conv-search p-[7px_8px] border-b border-border-custom flex gap-1.25 items-center min-w-0 shrink-0 group-[.collapsed]/conv-sidebar:p-0 group-[.collapsed]/conv-sidebar:h-full group-[.collapsed]/conv-sidebar:border-b-0 group-[.collapsed]/conv-sidebar:justify-center">
                <button id="btnCollapseConvList" class="tool-btn w-[26px] h-[26px] border border-border-custom rounded-[7px] bg-bg-elev text-muted cursor-pointer flex items-center justify-center transition-colors duration-140 hover:text-fg hover:bg-chip-bg hover:border-border-strong group-[.collapsed]/conv-sidebar:w-full group-[.collapsed]/conv-sidebar:h-full group-[.collapsed]/conv-sidebar:min-h-[72px] group-[.collapsed]/conv-sidebar:rounded-none group-[.collapsed]/conv-sidebar:border-none group-[.collapsed]/conv-sidebar:bg-transparent" data-i18n-title="conv.collapseList" title="收起列表"><span data-icon="chevronLeft"></span></button>
                <div class="search-field flex-1 min-w-0 flex items-center gap-1 bg-bg-input border border-border-custom rounded-[7px] px-1 py-0 pl-2 focus-within:border-primary group-[.collapsed]/conv-sidebar:hidden">
                  <input id="convSearch" class="flex-grow min-w-0 border-none bg-transparent py-1.25 text-fg text-[11.5px] outline-none" type="text" data-i18n-placeholder="conv.searchPlaceholder" placeholder="搜索项目 / 会话 / 内容…" />
                  <button class="search-clear shrink-0 border-none bg-transparent text-caption font-medium text-[10px] leading-none px-1.5 py-0.75 rounded cursor-pointer whitespace-nowrap transition-all duration-120 hover:text-fg hover:bg-chip-bg" id="convClear" type="button" data-i18n="conv.clear" data-i18n-title="conv.clearSearch" title="清空搜索">清空</button>
                </div>
                <button id="convImportBtn" class="tool-btn w-[26px] h-[26px] shrink-0 border border-border-custom rounded-[7px] bg-bg-elev text-muted cursor-pointer flex items-center justify-center text-[16px] leading-none transition-all duration-140 hover:text-fg hover:bg-chip-bg hover:border-border-strong group-[.collapsed]/conv-sidebar:hidden" type="button" data-i18n-title="conv.import" title="导入 .jsonl 记录">+</button>
              </div>
              <div id="convDirSwitch" class="conv-dir-switch hidden flex gap-1.5 px-3 py-2 border-b border-border-custom bg-bg-sidebar/20 flex-wrap"></div>
              <div id="convList" class="conv-list flex-1 overflow-y-auto group-[.collapsed]/conv-sidebar:hidden"></div>
            </aside>

            <div class="conv-resizer conv-resizer-left" data-resize="left" title="拖动调整宽度"></div>

            <main class="conv-main flex-grow min-w-0 flex flex-col bg-bg-elev">
              <div class="conv-detail-toolbar flex items-center gap-2 px-4 py-2 border-b border-border-custom h-10 shrink-0">
                <span class="search-icon" data-icon="search"></span>
                <input id="convDetailSearch" class="flex-grow border-none bg-transparent py-1.25 text-fg text-[11.5px] outline-none" style="min-width:200px" type="text" data-i18n-placeholder="conv.searchMsg" placeholder="搜索消息…" />
                <div class="conv-detail-search-controls flex items-center gap-[2px] shrink-0">
                  <span id="convDetailSearchCount" class="search-count text-[10px] text-caption font-mono min-w-8 text-center"></span>
                  <button id="convDetailSearchPrev" class="tool-btn w-[26px] h-[26px] border border-border-custom rounded-[7px] bg-bg-elev text-muted cursor-pointer flex items-center justify-center transition-all duration-140 hover:text-fg hover:bg-chip-bg hover:border-border-strong" data-i18n-title="conv.prev" title="上一个"><span>↑</span></button>
                  <button id="convDetailSearchNext" class="tool-btn w-[26px] h-[26px] border border-border-custom rounded-[7px] bg-bg-elev text-muted cursor-pointer flex items-center justify-center transition-all duration-140 hover:text-fg hover:bg-chip-bg hover:border-border-strong" data-i18n-title="conv.next" title="下一个"><span>↓</span></button>
                  <button id="convDetailSearchClear" class="tool-btn w-[26px] h-[26px] border border-border-custom rounded-[7px] bg-bg-elev text-muted cursor-pointer flex items-center justify-center transition-all duration-140 hover:text-fg hover:bg-chip-bg hover:border-border-strong" data-i18n-title="conv.clearSearch" title="清除"><span>✕</span></button>
                </div>
                <div id="convActions" class="flex items-center gap-2 shrink-0">
                <button id="convReplayBtn" class="no-drag inline-flex items-center gap-1.5 h-[28px] px-3 border border-border-custom rounded-[7px] bg-bg-elev text-muted cursor-pointer transition-all duration-140 hover:text-fg hover:bg-chip-bg hover:border-border-strong disabled:opacity-40 disabled:cursor-not-allowed whitespace-nowrap shrink-0" data-i18n-title="conv.replayHint" title="用 Claude 分析这段会话" disabled><img src="assets/claude.svg" alt="" class="shrink-0" style="width:15px;height:15px;border-radius:3px" /><span class="text-[11px] font-medium whitespace-nowrap" data-i18n="conv.replay">Claude 分析</span></button>
                <button id="convChatgptBtn" class="no-drag inline-flex items-center gap-1.5 h-[28px] px-3 border border-border-custom rounded-[7px] bg-bg-elev text-muted cursor-pointer transition-all duration-140 hover:text-fg hover:bg-chip-bg hover:border-border-strong disabled:opacity-40 disabled:cursor-not-allowed whitespace-nowrap shrink-0" data-i18n-title="conv.chatgptHint" title="用 ChatGPT 分析这段会话" disabled><img src="assets/chatgpt.svg" alt="" class="shrink-0" style="width:15px;height:15px;border-radius:3px" /><span class="text-[11px] font-medium whitespace-nowrap" data-i18n="conv.chatgpt">ChatGPT 分析</span></button>
                <button id="convCopyPathBtn" class="no-drag inline-flex items-center gap-1.5 h-[28px] px-3 border border-border-custom rounded-[7px] bg-bg-elev text-muted cursor-pointer transition-all duration-140 hover:text-fg hover:bg-chip-bg hover:border-border-strong disabled:opacity-40 disabled:cursor-not-allowed whitespace-nowrap shrink-0" data-i18n-title="conv.copyPathHint" title="复制 JSONL 路径" disabled><span data-icon="folder" class="shrink-0 inline-flex items-center"></span><span class="text-[11px] font-medium whitespace-nowrap" data-i18n="conv.copyPath">复制路径</span></button>
                <div class="conv-export-wrap relative shrink-0">
                  <button id="convExportBtn" class="no-drag inline-flex items-center gap-1.5 h-[28px] px-3 border border-border-custom rounded-[7px] bg-bg-elev text-muted cursor-pointer transition-all duration-140 hover:text-fg hover:bg-chip-bg hover:border-border-strong disabled:opacity-40 disabled:cursor-not-allowed whitespace-nowrap shrink-0" data-i18n-title="conv.export" title="导出" disabled><span data-icon="download" class="shrink-0 inline-flex items-center"></span><span class="text-[11px] font-medium whitespace-nowrap" data-i18n="conv.export">导出</span><span class="text-[8px] opacity-70 shrink-0">▾</span></button>
                  <div id="convExportMenu" class="conv-export-menu hidden absolute right-0 top-[32px] z-30 min-w-[170px] bg-bg-elev border border-border-custom rounded-[9px] shadow-[0_10px_30px_rgba(0,0,0,0.24)] p-1 animate-[panelIn_0.14s_ease]">
                    <button data-export="jsonl" class="conv-export-item w-full text-left px-2.5 py-1.5 rounded-[6px] text-[12px] text-fg cursor-pointer flex items-center gap-2 hover:bg-chip-bg"><span class="text-[13px]">📄</span><span data-i18n="conv.exportJsonl">导出 JSONL（原始）</span></button>
                    <button data-export="html" class="conv-export-item w-full text-left px-2.5 py-1.5 rounded-[6px] text-[12px] text-fg cursor-pointer flex items-center gap-2 hover:bg-chip-bg"><span class="text-[13px]">🌐</span><span data-i18n="conv.exportHtml">导出 HTML（可分享）</span></button>
                  </div>
                </div>
                </div>
                <div id="convMoreWrap" class="conv-more-wrap relative shrink-0 hidden">
                  <button id="convMoreBtn" class="no-drag inline-flex items-center justify-center h-[28px] w-[30px] border border-border-custom rounded-[7px] bg-bg-elev text-muted cursor-pointer transition-all duration-140 hover:text-fg hover:bg-chip-bg hover:border-border-strong disabled:opacity-40 disabled:cursor-not-allowed shrink-0" data-i18n-title="conv.more" title="更多" disabled><span class="text-[14px] leading-none">⋯</span></button>
                  <div id="convMoreMenu" class="conv-more-menu hidden absolute right-0 top-[32px] z-30 min-w-[190px] bg-bg-elev border border-border-custom rounded-[9px] shadow-[0_10px_30px_rgba(0,0,0,0.24)] p-1 animate-[panelIn_0.14s_ease]">
                    <button data-more="replay" class="w-full text-left px-2.5 py-1.5 rounded-[6px] text-[12px] text-fg cursor-pointer flex items-center gap-2 hover:bg-chip-bg"><img src="assets/claude.svg" alt="" style="width:15px;height:15px;border-radius:3px" /><span data-i18n="conv.replay">Claude 分析</span></button>
                    <button data-more="chatgpt" class="w-full text-left px-2.5 py-1.5 rounded-[6px] text-[12px] text-fg cursor-pointer flex items-center gap-2 hover:bg-chip-bg"><img src="assets/chatgpt.svg" alt="" style="width:15px;height:15px;border-radius:3px" /><span data-i18n="conv.chatgpt">ChatGPT 分析</span></button>
                    <button data-more="copyPath" class="w-full text-left px-2.5 py-1.5 rounded-[6px] text-[12px] text-fg cursor-pointer flex items-center gap-2 hover:bg-chip-bg"><span data-icon="folder" class="inline-flex items-center"></span><span data-i18n="conv.copyPath">复制路径</span></button>
                    <button data-more="jsonl" class="w-full text-left px-2.5 py-1.5 rounded-[6px] text-[12px] text-fg cursor-pointer flex items-center gap-2 hover:bg-chip-bg"><span class="text-[13px]">📄</span><span data-i18n="conv.exportJsonl">导出 JSONL（原始）</span></button>
                    <button data-more="html" class="w-full text-left px-2.5 py-1.5 rounded-[6px] text-[12px] text-fg cursor-pointer flex items-center gap-2 hover:bg-chip-bg"><span class="text-[13px]">🌐</span><span data-i18n="conv.exportHtml">导出 HTML（可分享）</span></button>
                  </div>
                </div>
              </div>
              <div id="convAgentTabs" class="conv-agent-tabs hidden items-center gap-1.5 px-4 py-1.5 border-b border-border-custom shrink-0 relative z-20"></div>
              <div id="convDetail" class="conv-detail flex-1 min-h-0 overflow-y-auto p-[22px_26px] flex flex-col gap-4">
                <div class="state-empty conv-empty m-auto max-w-[320px] border-none text-center px-5 py-8 text-muted text-[12px] leading-normal [&_p]:mb-3">
                  <div class="state-icon flex justify-center mb-2.5 text-caption" data-icon="conversations"></div>
                  <p data-i18n="conv.emptyTitle">选择左侧会话，查看完整对话历史</p>
                  <p class="muted small text-muted text-[11px]" data-i18n="conv.emptySub">数据来自 ~/.claude/projects · 活跃会话实时跟随</p>
                </div>
              </div>
            </main>

            <div class="conv-resizer conv-resizer-right" data-resize="right" title="拖动调整宽度"></div>

            <aside class="conv-nav group/conv-nav border-l border-border-custom flex flex-col shrink-0 overflow-hidden">
              <div class="conv-nav-top h-10 p-[7px_8px] border-b border-border-custom flex items-center justify-end group-[.collapsed]/conv-nav:p-0 group-[.collapsed]/conv-nav:h-full group-[.collapsed]/conv-nav:border-b-0 group-[.collapsed]/conv-nav:justify-center">
                <button id="btnCollapseConvNav" class="tool-btn w-[26px] h-[26px] border border-border-custom rounded-[7px] bg-bg-elev text-muted cursor-pointer flex items-center justify-center transition-colors duration-140 hover:text-fg hover:bg-chip-bg hover:border-border-strong group-[.collapsed]/conv-nav:w-full group-[.collapsed]/conv-nav:h-full group-[.collapsed]/conv-nav:min-h-[72px] group-[.collapsed]/conv-nav:rounded-none group-[.collapsed]/conv-nav:border-none group-[.collapsed]/conv-nav:bg-transparent" data-i18n-title="conv.collapsePanel" title="收起面板"><span data-icon="chevronRight"></span></button>
              </div>
              <div class="conv-nav-head text-[11px] font-semibold uppercase tracking-[0.03em] text-caption p-[14px_12px_6px] group-[.collapsed]/conv-nav:hidden" data-i18n="conv.overview">概览</div>
              <div id="convStats" class="conv-stats p-[0_12px_6px] group-[.collapsed]/conv-nav:hidden"></div>
              <div class="conv-nav-head text-[11px] font-semibold uppercase tracking-[0.03em] text-caption p-[14px_12px_6px] group-[.collapsed]/conv-nav:hidden" data-i18n="conv.nav">导航</div>
              <div id="convToc" class="conv-toc overflow-y-auto flex-1 p-[0_7px_10px] group-[.collapsed]/conv-nav:hidden"></div>
            </aside>
          </div>
        </section>`;
