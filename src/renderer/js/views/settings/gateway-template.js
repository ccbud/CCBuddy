/* 设置 → 网关 pane markup (verbatim from the former inline HTML). */
const SWITCH_TRACK = `<span class="track w-8 h-[17px] rounded-full bg-border-strong relative transition-colors duration-180 ease-[cubic-bezier(0.23,1,0.32,1)] shrink-0 peer-checked:bg-primary after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:w-[13px] after:h-[13px] after:rounded-full after:bg-white after:shadow-[0_1px_2px_rgba(0,0,0,0.18)] after:transition-transform after:duration-180 after:ease-[cubic-bezier(0.23,1,0.32,1)] peer-checked:after:translate-x-[15px]"></span>`;
export { SWITCH_TRACK };

export const GATEWAY_PANE_HTML = `
            <div data-pane="gateway" class="flex flex-col gap-7">
            <div class="settings-card bg-bg-elev border border-border-custom rounded-xl shadow-card p-7 flex flex-col gap-6 transition-all duration-300">
              <h3 class="settings-card-title text-[13px] font-semibold text-fg" data-i18n="settings.gateway">网关</h3>
              <p class="caption text-[12px] text-caption" data-i18n="settings.gatewayDesc">本机网关服务：接入的 CLI 都通过它转发请求。</p>
              <div class="flex items-center justify-between gap-3">
                <div class="min-w-0"><div class="text-[12.5px] font-medium text-fg" data-i18n="settings.gatewaySvc">网关服务</div><div class="text-[11.5px] text-caption mt-0.5" data-i18n="settings.gatewaySvcDesc">独立于接入配置的本机服务开关；停止后所有转发暂停，接入配置保持不变。</div></div>
                <label class="switch inline-flex items-center cursor-pointer no-drag shrink-0"><input id="fGatewayEnabled" type="checkbox" class="hidden peer" />${SWITCH_TRACK}</label>
              </div>
              <div class="endpoint-row flex items-center gap-2 flex-wrap">
                <code id="endpoint" class="endpoint flex-1 min-w-[180px] font-mono text-[12px] text-brand bg-bg-input border border-border-custom rounded-[7px] px-2.5 py-1.75">http://localhost:8788</code>
                <button class="btn btn-sm bg-bg-elev text-fg border border-border-custom rounded-md px-2.25 py-1.25 font-medium text-[11px] leading-none cursor-pointer transition-all duration-140 hover:bg-chip-bg hover:border-border-strong active:scale-[0.985]" data-copy="endpoint" data-i18n="settings.copy">复制</button>
                <label class="port-label text-[12px] text-muted flex items-center gap-1.25"><span data-i18n="settings.port">端口</span><input id="portInput" class="port-input w-[72px] px-1.75 py-1.25 bg-bg-input border border-border-custom rounded-md text-fg font-mono text-[12px] outline-none focus:border-primary" type="number" min="1" max="65535" /></label>
              </div>
              <pre id="exportBlock" data-clarity-mask="true" class="code-block font-mono text-[12px] leading-[1.55] !bg-[#0c0e12] !text-[#e8edf4] border border-white/8 rounded-lg px-3.25 py-2.75 overflow-x-auto"></pre>
              <div class="connect-actions flex items-center gap-2.5">
                <button class="btn btn-sm bg-bg-elev text-fg border border-border-custom rounded-md px-2.25 py-1.25 font-medium text-[11px] leading-none cursor-pointer transition-all duration-140 hover:bg-chip-bg hover:border-border-strong active:scale-[0.985]" id="btnCopyExport" data-i18n="settings.copyExport">复制 export</button>
                <span class="caption text-[12px] text-caption" id="claudePath" data-clarity-mask="true"></span>
              </div>
              <p class="caption warn text-[12px] text-caption [&.warn]:text-amber" data-i18n="settings.exportWarn">若曾在终端 export ANTHROPIC_BASE_URL，请删除以免覆盖。</p>
            </div>
            <div class="settings-card bg-bg-elev border border-border-custom rounded-xl shadow-card p-7 flex flex-col gap-6 transition-all duration-300">
              <h3 class="settings-card-title text-[13px] font-semibold text-fg" data-i18n="settings.connectTargets">接入目标</h3>
              <p class="caption text-[12px] text-caption" data-i18n="settings.connectTargetsDesc">选择「一键接入」要接管的编程 CLI；接入时自动写入各自的配置文件。</p>
              <div class="flex items-center justify-between gap-3">
                <div class="min-w-0 flex items-center gap-2"><div class="text-[12.5px] font-medium text-fg">Claude Code</div><span id="tgtClaudeChip" class="proto-badge proto-badge-direct"></span></div>
                <label class="switch inline-flex items-center cursor-pointer no-drag shrink-0"><input id="fTargetClaude" type="checkbox" class="hidden peer" />${SWITCH_TRACK}</label>
              </div>
              <div class="flex items-center justify-between gap-3 pt-4 border-t border-border-custom" id="targetCodexRow">
                <div class="min-w-0 flex items-center gap-2"><div class="text-[12.5px] font-medium text-fg">Codex</div><span id="tgtCodexChip" class="proto-badge proto-badge-direct"></span></div>
                <label class="switch inline-flex items-center cursor-pointer no-drag shrink-0"><input id="fTargetCodex" type="checkbox" class="hidden peer" />${SWITCH_TRACK}</label>
              </div>
              <p class="caption text-[12px] text-caption" id="targetCodexNote" data-i18n="settings.codexUnavailable" style="display:none">未检测到 Codex（~/.codex）。安装 Codex CLI 后可在此接入。</p>
            </div>
            <div class="settings-card bg-bg-elev border border-border-custom rounded-xl shadow-card p-7 flex flex-col gap-6 transition-all duration-300">
              <h3 class="settings-card-title text-[13px] font-semibold text-fg" data-i18n="settings.advanced">高级</h3>
              <div class="flex items-center justify-between gap-3">
                <div class="min-w-0"><div class="text-[12.5px] font-medium text-fg" data-i18n="settings.retry429">429 自动重试</div><div class="text-[11.5px] text-caption mt-0.5" data-i18n="settings.retry429Desc">供应商限流（429）时自动重试几次，再如实返回，减少偶发失败。</div></div>
                <label class="switch inline-flex items-center cursor-pointer no-drag shrink-0"><input id="fRetry429" type="checkbox" class="hidden peer" />${SWITCH_TRACK}</label>
              </div>
              <div class="flex items-center justify-between gap-3 pt-4 border-t border-border-custom">
                <div class="min-w-0"><div class="text-[12.5px] font-medium text-fg" data-i18n="settings.insecureTls">忽略上游 TLS 证书校验</div><div class="text-[11.5px] text-amber mt-0.5" data-i18n="settings.insecureTlsDesc">会降低安全性。仅在自签名 / 企业代理证书导致连接失败时临时开启，平时请保持关闭。</div></div>
                <label class="switch inline-flex items-center cursor-pointer no-drag shrink-0"><input id="fInsecureTls" type="checkbox" class="hidden peer" />${SWITCH_TRACK}</label>
              </div>
            </div>
            </div>`;
