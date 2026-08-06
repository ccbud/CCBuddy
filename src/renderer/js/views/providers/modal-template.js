/* 服务编辑 modal markup — injected on first open (kept out of the startup HTML). */
export const MODAL_HTML = `
    <div id="modal" class="overlay fixed inset-0 bg-black/28 flex items-center justify-center z-[100] backdrop-blur-md hidden">
      <div class="sheet w-[580px] max-w-[92vw] max-h-[86vh] overflow-y-auto bg-bg-elev backdrop-blur-[40px] border border-window-border rounded-2xl shadow-[0_24px_64px_rgba(0,0,0,0.18)] flex flex-col">
        <header class="sheet-head flex items-center gap-2 p-[14px_18px] border-b border-border-custom sticky top-0 bg-inherit z-2">
          <button class="tool-btn w-[26px] h-[26px] border border-border-custom rounded-[7px] bg-bg-elev text-muted cursor-pointer flex items-center justify-center transition-all duration-140 hover:text-fg hover:bg-chip-bg hover:border-border-strong" id="modalClose" data-i18n-title="modal.close" aria-label="关闭"><span data-icon="chevronLeft"></span></button>
          <h3 id="modalTitle" class="text-[14px] font-semibold tracking-tight" data-i18n="modal.addTitle">添加服务</h3>
        </header>
        <div class="sheet-body p-[18px_20px] flex flex-col gap-4 overflow-y-auto">
          <div class="preset-block flex flex-col gap-1.75">
            <span class="field-label text-[11px] font-semibold text-caption uppercase tracking-[0.03em]" data-i18n="modal.preset">预设</span>
            <div id="presetGrid" class="preset-grid flex flex-wrap gap-1.25"></div>
          </div>

          <div class="icon-center flex flex-col items-center gap-1 py-[2px]"><div class="prov-icon lg w-[52px] h-[52px] font-bold text-[18px] rounded-xl shrink-0 flex items-center justify-center text-white shadow-[0_1px_3px_rgba(0,0,0,0.1)] cursor-pointer transition-all duration-150 hover:ring-2 hover:ring-primary/40 hover:brightness-105 no-drag" id="fIconPreview" data-i18n-title="modal.iconEdit" title="点击自定义图标">C</div><span class="text-[10.5px] text-caption no-drag cursor-pointer" data-i18n="modal.iconHint">点击自定义图标</span></div>

          <div class="field-row flex gap-2.5">
            <label class="field flex flex-col gap-1.25 flex-1">
              <span class="field-label text-[11px] font-semibold text-caption uppercase tracking-[0.03em]" data-i18n="modal.name">名称</span>
              <input id="fName" class="bg-bg-input border border-border-custom rounded-[7px] px-2.75 py-2 text-fg text-[13px] font-mono w-full outline-none transition-colors duration-120 focus:border-primary" type="text" placeholder="GLM" />
            </label>
            <label class="field flex flex-col gap-1.25 flex-1">
              <span class="field-label text-[11px] font-semibold text-caption uppercase tracking-[0.03em]" data-i18n="modal.apiUrl">API 地址</span>
              <input id="fBaseUrl" data-clarity-mask="true" class="bg-bg-input border border-border-custom rounded-[7px] px-2.75 py-2 text-fg text-[13px] font-mono w-full outline-none transition-colors duration-120 focus:border-primary" type="text" placeholder="https://open.bigmodel.cn/api/anthropic/v1" />
            </label>
          </div>

          <div class="field flex flex-col gap-1.25">
            <span class="field-label text-[11px] font-semibold text-caption uppercase tracking-[0.03em] flex items-center gap-2">
              <span data-i18n="modal.protocol">上游协议</span>
              <span id="protoBadge" class="proto-badge proto-badge-direct"></span>
            </span>
            <div id="fProtocol" class="proto-seg no-drag" role="radiogroup">
              <button type="button" class="proto-seg-btn" data-proto="anthropic" data-i18n="modal.protoAnthropic">Anthropic Messages</button>
              <button type="button" class="proto-seg-btn" data-proto="openai-chat" data-i18n="modal.protoChat">OpenAI Chat</button>
              <button type="button" class="proto-seg-btn" data-proto="openai-responses" data-i18n="modal.protoResponses">OpenAI Responses</button>
            </div>
          </div>

          <label class="field flex flex-col gap-1.25 flex-1">
            <span class="field-label text-[11px] font-semibold text-caption uppercase tracking-[0.03em]" data-i18n="modal.apiKey">API Key</span>
            <span class="input-with-btn flex gap-1.75 items-center w-full">
              <input id="fToken" data-clarity-mask="true" class="bg-bg-input border border-border-custom rounded-[7px] px-2.75 py-2 text-fg text-[13px] font-mono w-full outline-none transition-colors duration-120 focus:border-primary flex-1" type="password" data-i18n-placeholder="modal.pasteKey" placeholder="粘贴密钥" />
              <button class="btn btn-sm bg-bg-elev text-fg border border-border-custom rounded-md px-2.25 py-1.25 font-medium text-[11px] leading-none cursor-pointer transition-all duration-140 hover:bg-chip-bg hover:border-border-strong active:scale-[0.985] shrink-0" id="fTokenToggle" type="button" data-i18n="modal.show">显示</button>
            </span>
          </label>

          <div class="field-row flex gap-2.5">
            <label class="field flex flex-col gap-1.25 flex-1">
              <span class="field-label text-[11px] font-semibold text-caption uppercase tracking-[0.03em]" data-i18n="modal.mainModel">主模型</span>
              <input id="fDefaultModel" class="bg-bg-input border border-border-custom rounded-[7px] px-2.75 py-2 text-fg text-[13px] font-mono w-full outline-none transition-colors duration-120 focus:border-primary" type="text" placeholder="glm-5.2" />
            </label>
            <label class="field flex flex-col gap-1.25 flex-1">
              <span class="field-label text-[11px] font-semibold text-caption uppercase tracking-[0.03em]" data-i18n="modal.smallModel">轻量模型</span>
              <input id="fSmallModel" class="bg-bg-input border border-border-custom rounded-[7px] px-2.75 py-2 text-fg text-[13px] font-mono w-full outline-none transition-colors duration-120 focus:border-primary" type="text" placeholder="glm-5.2-air" />
            </label>
          </div>

          <label class="switch inline-flex items-center gap-1.75 cursor-pointer text-[12.5px] no-drag">
            <input id="fMapDefault" type="checkbox" checked class="hidden peer" />
            <span class="track w-8 h-[17px] rounded-full bg-border-strong relative transition-colors duration-180 ease-[cubic-bezier(0.23,1,0.32,1)] shrink-0 peer-checked:bg-primary after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:w-[13px] after:h-[13px] after:rounded-full after:bg-white after:shadow-[0_1px_2px_rgba(0,0,0,0.18)] after:transition-transform after:duration-180 after:ease-[cubic-bezier(0.23,1,0.32,1)] peer-checked:after:translate-x-[15px]"></span>
            <span class="switch-label" data-i18n="modal.autoMap">自动映射 Claude 默认模型名</span>
          </label>

          <details class="disclosure mappings-details border border-border-custom rounded-xl bg-bg-elev overflow-hidden" open>
            <summary class="cursor-pointer text-[12.5px] text-muted outline-none list-none select-none [&::-webkit-details-marker]:hidden" data-i18n="modal.aliasSummary">自定义模型别名（别名 ⇄ 上游模型）</summary>
            <div class="mappings border border-border-custom rounded-lg p-3 mx-2.5 mt-2 mb-2.5 flex flex-col gap-1.75">
              <p class="caption text-[12px] text-caption" data-i18n="modal.aliasDesc">把客户端请求的模型名精确映射到上游模型，回包自动改回原名。带 [1m]（1M 上下文）等特殊模型务必在此显式映射到支持的上游，避免被自动映射降级。未命中别名时才走「自动映射」。</p>
              <div id="mapRows" class="map-rows flex flex-col gap-1.25"></div>
              <button class="btn btn-sm bg-bg-elev text-fg border border-border-custom rounded-md px-2.25 py-1.25 font-medium text-[11px] leading-none cursor-pointer transition-all duration-140 hover:bg-chip-bg hover:border-border-strong active:scale-[0.985] self-start" id="btnAddMap" type="button" data-i18n="modal.addMapping">+ 添加映射</button>
            </div>
          </details>

        </div>
        <footer class="sheet-foot flex items-center gap-2 p-3 border-t border-border-custom sticky bottom-0 bg-inherit z-2">
          <button class="btn bg-bg-elev text-fg border border-border-custom rounded-[7px] px-3 py-1.25 font-medium text-[12px] leading-none cursor-pointer transition-all duration-140 hover:bg-chip-bg hover:border-border-strong active:scale-[0.985]" id="btnTest" data-i18n="modal.test">连接测试</button>
          <span class="spacer flex-1"></span>
          <button class="btn ghost bg-transparent text-muted border-none rounded-[7px] px-3 py-1.25 font-medium text-[12px] leading-none cursor-pointer transition-all duration-140 hover:bg-chip-bg hover:text-fg active:scale-[0.985]" id="btnCancel" data-i18n="modal.cancel">取消</button>
          <button class="btn btn-primary bg-primary text-white border-none rounded-[7px] px-3 py-1.25 font-semibold text-[12px] leading-none cursor-pointer transition-all duration-140 hover:bg-primary-hover active:scale-[0.985]" id="btnSave" data-i18n="modal.save">保存</button>
        </footer>
      </div>
    </div>`;
