// The self-check probes injected into the main and popover webviews by run()'s on_page_load
// hook (gated by CCBUD_SELFCHECK). String literals only, moved verbatim from lib.rs.

pub(crate) const SELFCHECK_JS: &str = r#"
(function(){
  if (window.__ccbud_sc) return; window.__ccbud_sc = 1;
  window.__ccbud_errors = [];
  window.addEventListener('error', function(e){ try{window.__ccbud_errors.push(String((e&&e.message)||(e&&e.error)||e));}catch(_){} }, true);
  window.addEventListener('unhandledrejection', function(e){ try{window.__ccbud_errors.push('promise:'+String((e.reason&&e.reason.message)||e.reason));}catch(_){} });
  function rep(o){ try{ window.__TAURI__.core.invoke('selfcheck_report',{report:o}); }catch(_){} }
  setTimeout(async function(){
    var o={};
    try{
      o.hasCcbud=!!window.ccbud;
      o.hasTauri=!!(window.__TAURI__&&window.__TAURI__.core);
      o.bodyLen=(document.body&&document.body.innerHTML.length)||0;
      o.navItems=document.querySelectorAll('.nav-item,[data-view],[data-nav]').length;
      o.colorMix=!!(window.CSS&&CSS.supports&&CSS.supports('color','color-mix(in srgb,red,blue)'));
      o.highlight=!!(window.CSS&&CSS.highlights);
      // store round-trip — self-check runs point CCBUD_HOME at a throwaway dir
      try{
        var before=await window.ccbud.getConfig();
        o.provBefore=((before&&before.providers)||[]).length;
        var saved=await window.ccbud.upsertProvider({name:'SelfTest',baseUrl:'https://x.test',authToken:'tok',defaultModel:'m1',smallFastModel:'m1',extra:'shouldDrop'});
        o.provAfter=((saved&&saved.providers)||[]).length;
        o.savedName=saved&&saved.providers&&saved.providers[0]&&saved.providers[0].name;
        o.savedHasId=!!(saved&&saved.providers&&saved.providers[0]&&saved.providers[0].id);
        o.savedActiveMatches=!!(saved&&saved.activeProviderId&&saved.providers[0]&&saved.activeProviderId===saved.providers[0].id);
        o.droppedExtra=!(saved&&saved.providers&&saved.providers[0]&&('extra' in saved.providers[0]));
        var reread=await window.ccbud.getConfig();
        o.rereadProv=((reread&&reread.providers)||[]).length;
      }catch(e){ o.storeErr=String(e); }
      try{ o.routing=await window.__TAURI__.core.invoke('selfcheck_routing'); }catch(e){ o.routingErr=String(e); }
      try{ o.server=await window.ccbud.serverStatus(); }catch(e){ o.serverErr=String(e); }
      try{ o.gateway=await window.__TAURI__.core.invoke('selfcheck_gateway'); }catch(e){ o.gatewayErr=String(e); }
      try{
        o.histDirs=(await window.ccbud.historyDirs()).dirs.length;
        var hl=await window.ccbud.historyList();
        o.histCount=(hl||[]).length;
        o.histSample=hl&&hl[0]?{title:String(hl[0].title||'').slice(0,40),project:hl[0].project,hasCwd:!!hl[0].cwd,hasFile:!!hl[0].file}:null;
        if(hl&&hl[0]){ var ss=await window.ccbud.historyGet(hl[0].file); o.histMsgs=ss&&ss.messages?ss.messages.length:-1; o.histTotals=ss&&ss.meta?ss.meta.totals:null; }
      }catch(e){ o.histErr=String(e); }
      try{ var ug=await window.ccbud.usageGet('all'); o.usage={tokens:ug.tokens,requests:ug.requests,fav:ug.favoriteModel,heatmap:(ug.heatmap||[]).length,byModel:(ug.byModel||[]).length,activeDays:ug.activeDays}; }catch(e){ o.usageErr=String(e); }
      try{ var cc=await window.ccbud.connect(); var s1=await window.ccbud.serverStatus(); var dd=await window.ccbud.disconnect(); var s2=await window.ccbud.serverStatus(); o.claude={connOk:cc&&cc.ok,connected:s1.connected,discOk:dd&&dd.ok,afterDisc:s2.connected}; }catch(e){ o.claudeErr=String(e); }
      try{ o.copyOk=await window.ccbud.copy('selfcheck-clip'); }catch(e){ o.copyErr=String(e); }
      try{ o.histMeta=await window.__TAURI__.core.invoke('selfcheck_history'); }catch(e){ o.histMetaErr=String(e); }
      try{ o.export=await window.__TAURI__.core.invoke('selfcheck_export'); }catch(e){ o.exportErr=String(e); }
      try{ o.import=await window.__TAURI__.core.invoke('selfcheck_import'); }catch(e){ o.importErr=String(e); }
      try{ var us=await window.ccbud.updateState(); var sa=await window.ccbud.updateSetAuto({check:false}); o.update={current:us.current,status:us.status,setAutoCheck:sa.check}; }catch(e){ o.updateErr=String(e); }
      try{ o.drag={regions:document.querySelectorAll('.drag-region').length,wired:document.querySelectorAll('[data-tauri-drag-region]').length}; }catch(e){ o.dragErr=String(e); }
      try{ var cs=getComputedStyle(document.body); o.userSelect=cs.webkitUserSelect||cs.userSelect; }catch(e){}
      try{ var ep=document.getElementById('endpoint'); var eb=document.getElementById('exportBlock'); o.epSel=ep?getComputedStyle(ep).webkitUserSelect:'-'; o.ebSel=eb?getComputedStyle(eb).webkitUserSelect:'-'; }catch(e){}
      try{ o.popoverPos=await window.__TAURI__.core.invoke('selfcheck_popover'); }catch(e){ o.popoverPosErr=String(e); }
      o.errors=window.__ccbud_errors.slice(0,20);
    }catch(e){o.fatal=String((e&&e.stack)||e);}
    rep(o);
  },2200);
})();
"#;

pub(crate) const POPOVER_SELFCHECK_JS: &str = r#"
(function(){
  setTimeout(async function(){
    var o={win:"popover"};
    try{ o.hasCcbud=!!window.ccbud; var u=await window.ccbud.usageGet("all"); o.usageTokens=u?u.tokens:"null"; o.heatmapLen=u&&u.heatmap?u.heatmap.length:-1; o.heatmapFilled=u&&u.heatmap?u.heatmap.filter(function(c){return c.level>0;}).length:-1; }catch(e){ o.usageErr=String(e); }
    try{ var st=document.getElementById("sTokens"); o.sTokensText=st?st.textContent:"noel"; var hm=document.getElementById("heatmap"); o.heatCells=hm?hm.children.length:-1; }catch(e){}
    try{
      o.innerW=window.innerWidth; o.innerH=window.innerHeight; o.scrollH=document.body.scrollHeight;
      var st2=document.getElementById("sTokens"); if(st2){var r=st2.getBoundingClientRect(); o.sTokTop=Math.round(r.top); o.sTokVisible=(r.top>=0&&r.bottom<=window.innerHeight);}
      var hm2=document.getElementById("heatmap"); if(hm2){var hr=hm2.getBoundingClientRect(); o.hmTop=Math.round(hr.top); o.hmBottom=Math.round(hr.bottom);}
      o.bodyBg=getComputedStyle(document.body).backgroundColor;
      var root=document.querySelector(".pop-body-root"); o.rootBg=root?getComputedStyle(root).backgroundColor:"noel";
    }catch(e){ o.visErr=String(e); }
    try{ window.__TAURI__.core.invoke("selfcheck_report",{report:o}); }catch(_){}
  }, 1500);
})();
"#;
