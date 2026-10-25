'use strict';
/* Fleet shell (docs/UNIFIED-UI.md sections 3.1, 5 and 6). Loaded synchronously in <head> so the
   theme and sidebar state apply before first paint; the buttons are wired once the DOM exists.
   Storage may be unavailable (private windows, blocked site data): everything still works. */
(function(){
 const root=document.documentElement;
 const THEME_KEY='packetrat-theme',SIDEBAR_KEY='packetrat-sidebar';
 const load=key=>{try{return window.localStorage.getItem(key)}catch{return null}};
 const save=(key,value)=>{try{if(value===null)window.localStorage.removeItem(key);else window.localStorage.setItem(key,value)}catch{}};
 const themes={system:['Follow Windows','themeSystem'],dark:['Night watch','themeDark'],light:['Chart room','themeLight']};
 const nextTheme={system:'dark',dark:'light',light:'system'};
 let theme=load(THEME_KEY);if(theme!=='dark'&&theme!=='light')theme='system';
 function applyTheme(){if(theme==='system')root.removeAttribute('data-theme');else root.setAttribute('data-theme',theme)}
 applyTheme();
 // Narrower than 1024 px the sidebar collapses by itself; the stored choice applies above that.
 const narrow=window.matchMedia('(max-width: 1023px)');
 let collapsed=load(SIDEBAR_KEY)==='collapsed';
 function applySidebar(){root.classList.toggle('sidebar-collapsed',collapsed||narrow.matches)}
 applySidebar();

 const icon=(name,size)=>window.PacketRatIcons?window.PacketRatIcons.svg(name,size):'';
 function renderTheme(){
  const button=document.getElementById('themeToggle');if(!button)return;
  const [name,iconName]=themes[theme],[nextName]=themes[nextTheme[theme]];
  document.getElementById('themeLabel').textContent=name;
  const glyph=document.getElementById('themeIcon');glyph.dataset.icon=iconName;glyph.innerHTML=icon(iconName,20);
  button.title='Theme: '+name+'. Click for '+nextName+'.';
  button.setAttribute('aria-label','Theme: '+name+'. Switch to '+nextName);
 }
 function renderSidebar(){
  const button=document.getElementById('sidebarToggle');if(!button)return;
  const isCollapsed=collapsed||narrow.matches;
  button.hidden=narrow.matches;
  button.setAttribute('aria-expanded',String(!isCollapsed));
  button.title=isCollapsed?'Expand the sidebar':'Collapse the sidebar';
  const glyph=document.getElementById('sidebarIcon');const name=isCollapsed?'expand':'collapse';glyph.dataset.icon=name;glyph.innerHTML=icon(name,20);
 }
 const onNarrow=()=>{applySidebar();renderSidebar()};
 if(narrow.addEventListener)narrow.addEventListener('change',onNarrow);else if(narrow.addListener)narrow.addListener(onNarrow);

 // Dialogs: focus moves in, Tab stays inside, Esc closes (native <dialog> cancel), focus returns.
 const FOCUSABLE='button:not([disabled]),[href],input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])';
 function trackDialog(dialog){
  let previous=null;
  new MutationObserver(()=>{
   if(dialog.open){previous=document.activeElement}
   else if(previous&&document.contains(previous)&&typeof previous.focus==='function'){previous.focus();previous=null}
  }).observe(dialog,{attributes:true,attributeFilter:['open']});
 }
 function trapTab(event){
  if(event.key!=='Tab')return;
  const dialog=[...document.querySelectorAll('dialog[open]')].pop();if(!dialog)return;
  const items=[...dialog.querySelectorAll(FOCUSABLE)].filter(el=>el.offsetParent!==null);if(!items.length)return;
  const first=items[0],last=items[items.length-1];
  if(!dialog.contains(document.activeElement)){event.preventDefault();first.focus();return}
  if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus()}
  else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus()}
 }
 function openShortcuts(){const dialog=document.getElementById('shortcutsDialog');if(dialog&&!dialog.open)dialog.showModal()}
 const typing=target=>target&&(target.isContentEditable||/^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName));

 function wire(){
  if(window.PacketRatIcons)window.PacketRatIcons.hydrate(document);
  renderTheme();renderSidebar();
  document.getElementById('themeToggle')?.addEventListener('click',()=>{theme=nextTheme[theme];applyTheme();save(THEME_KEY,theme==='system'?null:theme);renderTheme()});
  document.getElementById('sidebarToggle')?.addEventListener('click',()=>{collapsed=!collapsed;save(SIDEBAR_KEY,collapsed?'collapsed':'expanded');applySidebar();renderSidebar()});
  document.getElementById('shortcutsButton')?.addEventListener('click',openShortcuts);
  document.getElementById('closeShortcuts')?.addEventListener('click',()=>document.getElementById('shortcutsDialog').close());
  document.querySelectorAll('dialog').forEach(trackDialog);
  document.addEventListener('keydown',trapTab,true);
  document.addEventListener('keydown',event=>{if(event.key==='?'&&!event.ctrlKey&&!event.metaKey&&!event.altKey&&!typing(event.target)&&!document.querySelector('dialog[open]')){event.preventDefault();openShortcuts()}});
 }
 if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',wire);else wire();
})();
