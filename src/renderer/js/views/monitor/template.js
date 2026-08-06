/* 监控 view + request inspector drawer markup — injected on first switch/open. */
export const MONITOR_HTML = `
        <section id="view-monitor" class="panel hidden flex-none max-w-[1120px] mx-auto px-10 pt-4 pb-10 w-full flex flex-col gap-6 animate-[panelIn_0.28s_ease-[cubic-bezier(0.23,1,0.32,1)]]">
          <div class="metric-grid grid grid-cols-4 gap-3.5">
            <div class="metric bg-bg-elev border border-border-custom rounded-[16px] p-5 shadow-card flex flex-col gap-2">
              <span class="metric-label text-[11px] font-semibold uppercase tracking-[0.03em] text-caption" data-i18n="monitor.gateway">网关</span>
              <span class="metric-value sm text-[15px] font-bold tracking-[-0.02em] leading-[1.15] flex items-center gap-1.5" id="mStatus"><span class="pulse-dot w-2 h-2 rounded-full bg-muted transition-colors duration-200 [&.on]:bg-green [&.on]:animate-pulse off"></span><span id="mStatusText" data-i18n="status.disconnected">未接入</span></span>
              <span class="metric-sub text-[11px] text-muted truncate" id="mEndpoint">localhost:8788</span>
            </div>
            <div class="metric bg-bg-elev border border-border-custom rounded-[16px] p-5 shadow-card flex flex-col gap-2">
              <span class="metric-label text-[11px] font-semibold uppercase tracking-[0.03em] text-caption" data-i18n="monitor.activeService">活跃服务</span>
              <span class="metric-value sm text-[15px] font-bold tracking-[-0.02em] leading-[1.15] flex items-center gap-1.5" id="mActive">—</span>
              <span class="metric-sub text-[11px] text-muted truncate" id="mActiveUrl" data-clarity-mask="true">—</span>
            </div>
            <div class="metric bg-bg-elev border border-border-custom rounded-[16px] p-5 shadow-card flex flex-col gap-2">
              <span class="metric-label text-[11px] font-semibold uppercase tracking-[0.03em] text-caption" data-i18n="monitor.totalReq">总请求</span>
              <span class="metric-value mono text-[20px] font-bold tracking-[-0.02em] leading-[1.15] flex items-center gap-1.5 font-mono" id="mTotal">0</span>
              <span class="metric-sub text-[11px] text-muted truncate" id="mSuccess">—</span>
            </div>
            <div class="metric bg-bg-elev border border-border-custom rounded-[16px] p-5 shadow-card flex flex-col gap-2">
              <span class="metric-label text-[11px] font-semibold uppercase tracking-[0.03em] text-caption" data-i18n="monitor.avgLatency">平均耗时</span>
              <span class="metric-value mono text-[20px] font-bold tracking-[-0.02em] leading-[1.15] flex items-center gap-1.5 font-mono" id="mAvg">— <span class="unit">ms</span></span>
              <span class="metric-sub text-[11px] text-muted truncate" id="mLast">—</span>
            </div>
          </div>

          <div class="panel-toolbar flex items-center justify-between px-[2px] py-1">
            <h2 class="panel-label text-[12.5px] font-semibold tracking-[0.04em] uppercase text-caption" data-i18n="monitor.reqStream">请求流</h2>
            <div class="toolbar-end flex items-center gap-2.5">
              <span class="caption text-[12px] text-caption" id="streamHint" data-i18n="monitor.waiting">等待请求</span>
              <button class="btn btn-sm bg-bg-elev text-fg border border-border-custom rounded-md px-2.25 py-1.25 font-medium text-[11px] leading-none cursor-pointer transition-all duration-140 hover:bg-chip-bg hover:border-border-strong active:scale-[0.985]" id="btnClearLog" data-i18n="monitor.clear">清空</button>
            </div>
          </div>
          <div id="streamList" class="stream-list bg-bg-elev border border-border-custom rounded-xl overflow-hidden shadow-card">
            <div class="state-inline p-4 text-center text-[11.5px] text-caption" data-i18n="monitor.streamEmpty">接入网关后，转发记录将实时显示</div>
          </div>

          <details class="disclosure raw-log-wrap border border-border-custom rounded-xl bg-bg-elev overflow-hidden">
            <summary class="flex items-center gap-2 px-3.5 py-2.25 cursor-pointer text-[12px] font-semibold text-muted list-none outline-none select-none [&::-webkit-details-marker]:hidden [details[open]_>_&]:border-b [details[open]_>_&]:border-border-custom"><span data-i18n="monitor.gatewayLog">网关日志</span><span id="gwLogStatus" class="raw-log-badge ml-auto"></span></summary>
            <div id="rawLog" data-clarity-mask="true" class="raw-log font-mono text-[10.5px] text-caption px-3.5 pb-3 max-h-[150px] overflow-y-auto leading-[1.55]"></div>
          </details>
        </section>`;

export const DRAWER_HTML = `
    <div id="reqDrawer" class="drawer-overlay fixed inset-0 z-50 bg-[#111827]/28 backdrop-blur-[2px] flex justify-end animate-[fadeIn_0.16s_ease-[cubic-bezier(0.23,1,0.32,1)]] hidden">
      <aside class="drawer w-[min(640px,82vw)] h-full bg-bg-elev border-l border-border-custom shadow-[-12px_0_40px_rgba(17,24,39,0.18)] flex flex-col animate-[drawerIn_0.24s_ease-[cubic-bezier(0.23,1,0.32,1)]]">
        <header class="drawer-head flex items-center gap-2.5 p-[16px_16px_12px] border-b border-border-custom">
          <div class="drawer-title flex items-center gap-2.5 flex-1 min-w-0 font-mono text-[13px]">
            <span class="dr-method font-bold text-brand" id="drMethod">POST</span>
            <span class="dr-status font-bold px-2 py-0.25 rounded-full text-[12px] [&.ok]:text-green [&.ok]:bg-green-soft [&.err]:text-red [&.err]:bg-red-soft" id="drStatus">—</span>
            <span class="dr-model text-muted truncate [&_.arrow]:text-caption [&_.arrow]:mx-[2px] [&_.rewrite]:text-amber" id="drModel"></span>
          </div>
          <button class="tool-btn w-[26px] h-[26px] border border-border-custom rounded-[7px] bg-bg-elev text-muted cursor-pointer flex items-center justify-center transition-all duration-140 hover:text-fg hover:bg-chip-bg hover:border-border-strong" id="reqDrawerClose" data-i18n-title="drawer.close" aria-label="关闭"><span>✕</span></button>
        </header>
        <div class="drawer-meta flex flex-wrap gap-1.5 p-[12px_16px] border-b border-border-custom" id="reqMeta"></div>
        <!-- Tabs are rendered per exchange: 2 tabs for passthrough, 4 for a
             protocol-translated exchange (client req / upstream req / upstream res / client res). -->
        <div class="drawer-tabs flex gap-1 p-[10px_16px_0] border-b border-border-custom" id="drTabs"></div>
        <div class="drawer-body flex-grow min-h-0 overflow-y-auto p-[4px_16px_24px]" id="reqDrawerBody" data-clarity-mask="true"></div>
      </aside>
    </div>`;
