'use strict';
/* PacketRat browser client: no secrets, external libraries, or automatic email sending. */
const $=id=>document.getElementById(id);
const demo=new URLSearchParams(location.search).get('demo')==='1'||document.documentElement.dataset.demo==='1';
const token=document.querySelector('meta[name="packetrat-token"]')?.content||'';
const names={overview:'Overview',triage:'Action queue',report:'AI intelligence',dismissals:'Dismissal memory',settings:'Configuration'};
let store={Checklist:[],Dismissals:[]},report='',lastRun=null,filter='all',draftKey='',busy=false,noticeTimer=null;
let ruleDraft=null,draftVersion=null;
let reportItems=[],reportSections=[],reportStructure=[],reportQuality=null,generatedReportText='';
const reportUI=window.PacketRatReport;
let credentialDetails=null;
// Lucide icons (icons.js); empty when icons.js is not loaded, so the app still works.
const icon=(name,size)=>window.PacketRatIcons?window.PacketRatIcons.svg(name,size):'';
/* Status bar (docs/UNIFIED-UI.md section 5): engine dot plus a word, never colour alone. */
const engineWords={connecting:'Connecting',running:'Running',busy:'Working',disconnected:'Disconnected',stopped:'Stopped',demo:'Demo'};
function setEngine(state){const el=$('engineState');if(!el)return;el.className='engine engine-'+state;$('engineWord').textContent=engineWords[state]||state}
function setSession(text){const el=$('connectionStatus');if(el)el.textContent=text}
const escapeHtml=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const defaultRules=[
 {Id:'security',Name:'Security / mandatory action',Enabled:true,Match:'SecurityAction',Value:'',Effect:'High'},
 {Id:'directorg',Name:'Direct request from your organization',Enabled:true,Match:'DirectOrgRequest',Value:'',Effect:'High'},
 {Id:'directask',Name:'Direct request or question',Enabled:true,Match:'DirectRequest',Value:'',Effect:'Medium'},
 {Id:'replied',Name:'Already replied, no new request',Enabled:true,Match:'AlreadyReplied',Value:'',Effect:'Skip'},
 {Id:'automated',Name:'Routine automated digest',Enabled:true,Match:'AutomatedDigest',Value:'',Effect:'Skip'}
];
const fakeItems=[
 {Key:'demo-1',EntryID:'',Subject:'Action required: review access request',From:'Morgan Lee',Why:'Approval requested for a pending access workflow',Urgency:'High',Status:'open',CreatedAt:new Date().toISOString()},
 {Key:'demo-2',EntryID:'',Subject:'Upcoming project milestone confirmation',From:'Taylor Brooks',Why:'A response confirming target dates is requested',Urgency:'High',Status:'in_progress',CreatedAt:new Date().toISOString()},
 {Key:'demo-3',EntryID:'',Subject:'Please review the updated draft',From:'Jordan Kim',Why:'Review and return comments on an attached document',Urgency:'Medium',Status:'open',CreatedAt:new Date().toISOString()},
 {Key:'demo-4',EntryID:'',Subject:'Meeting agenda feedback',From:'Sam Rivera',Why:'Feedback already provided',Urgency:'Low',Status:'done',CreatedAt:new Date().toISOString()}
];
const demoReport=`## 1. Categories
> **Triage overview** — 3 action requests, 1 completed response.

## 2. Groups
| Email # | Sender | Subject | Suggested disposition |
| --- | --- | --- | --- |
| [Email #1] | Morgan Lee | Action required: review access request | High |
| [Email #2] | Taylor Brooks | Upcoming milestone confirmation | High |
| [Email #3] | Jordan Kim | Please review the updated draft | Medium |
| [Email #4] | Sam Rivera | Meeting agenda feedback | Already replied |

## 3. Must Reply
- [Email #1] Please approve the access workflow. Donâ€™t assume approval happened.
- [Email #2] Review timing â€“ confirm project milestones.
- [Email #3] Review the attached draft.

## 4. Already Appears Replied / No Action Needed
- [Email #4] Completed; no new ask detected.
- [Email #5] Routine schedule update (FYI; not tracked).

## 5. Skipped / Caution
> Caution: Check original Outlook messages before replying.

## 6. Quick Summary
Three pending requests. This is test data, not a live AI response.`;
function demoReportItems(){
 const linked=fakeItems.map((item,i)=>({
  Index:i+1,Key:item.Key,Subject:item.Subject,From:item.From,FromEmail:'demo@example.test',
  Section:i===3?'Already Replied':'Must Reply',Reason:item.Why,
  RecommendedAction:i===3?'No response needed.':'Review and respond to the verified request.',
  Urgency:item.Urgency,Tracked:true,SourceVerified:true
 }));
 linked.push({Index:5,Key:'demo-5',Subject:'FYI: schedule update',From:'Office Updates',
  FromEmail:'demo-fyi@example.test',Section:'No Action Needed',Reason:'Routine FYI, not in the action queue.',
  RecommendedAction:'',Urgency:'Unrated',Tracked:false,SourceVerified:true});
 return linked;
}
function demoStructuredReport(){
 return [
  {Id:'categories',Title:'1. Categories',Summary:'Triage overview: 3 action requests and 1 completed response.',Items:[
    {EmailIndex:1,Text:'Approval needs review.'},{EmailIndex:2,Text:'Confirm project milestone dates.'}]},
  {Id:'groups',Title:'2. Groups',Summary:'Work is grouped by required follow-up.',Items:[
    {EmailIndex:3,Text:'Document review and comments requested.'}]},
  {Id:'must_reply',Title:'3. Must Reply',Summary:'Three pending requests need human review.',Items:[
    {EmailIndex:1,Text:'Donâ€™t assume access was approved.'},
    {EmailIndex:2,Text:'Confirm timing â€“ dates remain unverified.'},
    {EmailIndex:3,Text:'Review the revised document.'}]},
  {Id:'already_replied',Title:'4. Already Replied / No Action Needed',Summary:'One reply was completed; one FYI is untracked.',Items:[
    {EmailIndex:4,Text:'Original question was already answered.'},
    {EmailIndex:5,Text:'Routine schedule FYI only.'}]},
  {Id:'skipped',Title:'5. Skipped / Caution',Summary:'Source verification is required before acting.',Items:[]},
  {Id:'quick_summary',Title:'6. Quick Summary',Summary:'Review three active tasks; no real Outlook or AI data was used.',Items:[]}
 ];
}
function demoDefault(){return {Checklist:fakeItems.map(x=>({...x})),Dismissals:[],Rules:defaultRules.map(x=>({...x})),UpdatedAt:new Date().toISOString()};}
function demoStore(){try{const x=JSON.parse(sessionStorage.getItem('packetrat-demo-store')||'null');return x&&Array.isArray(x.Checklist)&&Array.isArray(x.Dismissals)?{...x,Rules:Array.isArray(x.Rules)?x.Rules:defaultRules.map(r=>({...r}))}:demoDefault()}catch{return demoDefault()}}
function demoPersist(){sessionStorage.setItem('packetrat-demo-store',JSON.stringify(store));}
async function api(route,data){
 if(demo){await new Promise(resolve=>setTimeout(resolve,140));if(route==='state')return {ok:true,store:demoStore(),report:demoReport,reportStructure:demoStructuredReport(),responseProtocol:'PACKETRAT_REPORT_V1',reportItems:demoReportItems(),reportSections:reportUI.deriveSections(demoReport),reportQuality:{Warnings:[],VerifiedSources:4,HasStructuredReferences:true},lastRun:{AnalyzedCount:4,Provider:'DEMO'},metadata:{profile:'Demo',model:'Sample'}};
  if(route==='log')return {ok:true,entries:[{seq:1,time:'2026-10-31T09:00:00Z',action:'item.dismiss',key:'demo-1',result:'ok'}],verify:{ok:true,count:1,tip:'0'.repeat(64),problemAtLine:0,reason:''}};
  if(route==='log/verify')return {ok:true,verify:{ok:true,count:1,tip:'0'.repeat(64),problemAtLine:0,reason:''}};
  if(route==='voice/status'){try{const r=await fetch('/api/voice/status',{cache:'no-store'});if(r.ok)return await r.json()}catch{}return {ok:true,voice:{installed:false}}}
  if(route==='assist/ask')return {ok:true,say:'In the sample data, the budget approval is most urgent.',proposals:[]};
  if(route==='assist/brief')return {ok:true,briefing:{say:'Bridge, you have 4 open actions in the sample data, 1 high priority.',openCount:4,highCount:1,items:[]}};
  if(route==='credentials/status')return {ok:true,credentials:{source:'Lazarette',manual:{AiEndpoint:false,Grok:false},lazaretteDetected:false,lazaretteItems:{AiEndpoint:'ai-endpoint-api',Grok:'grok-api'}}};
   if(route==='credentials'||route==='credentials/clear')return {ok:true,credentials:{source:data?.source||'Lazarette',manual:{AiEndpoint:false,Grok:false},lazaretteDetected:false,lazaretteItems:{AiEndpoint:'ai-endpoint-api',Grok:'grok-api'}}};
   if(route==='analyze'){store=demoStore();demoPersist();return {ok:true,store,report:demoReport,reportStructure:demoStructuredReport(),responseProtocol:'PACKETRAT_REPORT_V1',reportItems:demoReportItems(),reportSections:reportUI.deriveSections(demoReport),reportQuality:{Warnings:[],VerifiedSources:4,HasStructuredReferences:true},summary:{AnalyzedCount:4,Provider:'DEMO'},metadata:{profile:'Demo',model:'Sample'}}}
  const key=String(data?.key||''),item=store.Checklist.find(x=>x.Key===key);
  if(route==='report/generate'){
   const modes={Brief:'Leadership briefing',Actions:'Prioritized action plan',Risks:'Risk and uncertainty review',Explain:'Plain-language explanation'};
   return {ok:true,generated:{Mode:data.mode,Section:data.sectionId==='all'?'Full report':'Selected section',Content:'## '+(modes[data.mode]||'Summary')+'\n\n- Verify [Email #1] in Outlook.\n- Confirm [Email #2] timing.\n- This is simulated analysis. No AI or email account was contacted.',Profile:'Demo',Model:'Sample'}};
  }
  if(route==='report/track'){const source=demoReportItems().find(x=>x.Key===String(data.key));if(!source)throw Error('Unknown demo source');if(!item){store.Checklist.push({Key:source.Key,EntryID:'',Subject:source.Subject,From:source.From,Why:source.Reason,Urgency:data.urgency||'Medium',Status:'open',PriorityOverride:true,TriageSource:'Manual'})}demoPersist();return {ok:true,store}}
  if(route==='priority'){if(!item)throw Error('Unknown demo item');item.Urgency=data.urgency;item.PriorityOverride=true;item.TriageSource='Manual';item.RuleSuppressed=false;demoPersist();return {ok:true,store}}
  if(route==='priority/reset'){if(!item)throw Error('Unknown demo item');item.PriorityOverride=false;item.TriageSource='AI';demoPersist();return {ok:true,store}}
  if(route==='rules'){store.Rules=data.rules.map(r=>({...r}));demoPersist();return {ok:true,store}}
  if(route==='status'){if(!item)throw Error('Unknown demo item');item.Status=data.status;demoPersist();return {ok:true,store}}
  if(route==='dismiss'){if(!item)throw Error('Unknown demo item');item.Status='dismissed';store.Dismissals=[...store.Dismissals.filter(x=>x.Key!==key),{Key:key,Subject:item.Subject,From:item.From,Reason:data.reason||'No action needed'}];demoPersist();return {ok:true,store}}
  if(route==='restore'){store.Dismissals=store.Dismissals.filter(x=>x.Key!==key);if(item)item.Status='open';demoPersist();return {ok:true,store}}
  if(route==='draft'){return {ok:true,draft:{
    Version:'PACKETRAT_DRAFT_V1',Subject:'RE: '+String(item?.Subject||'Request'),
    Body:'Thank you for the update. I will review the details and follow up with you shortly. Please let me know if there is a deadline I should prioritize.',
    Draft:'Thank you for the update. I will review the details and follow up with you shortly.',
    SignatureSource:'OutlookReply',Profile:'Demo',OutputTokenBudget:20000
   }}}
  if(route==='item/archive'){if(!item)throw Error('Unknown demo item');item.Status='dismissed';store.Dismissals=[...store.Dismissals.filter(x=>x.Key!==key),{Key:key,Subject:item.Subject,From:item.From,Reason:'Archived'}];demoPersist();return {ok:true,store,demoOnly:true}}
  if(route==='item/move'||route==='item/categorize'||route==='item/mark-read')return {ok:true,store,demoOnly:true};
  if(route==='open'||route==='open-draft')return {ok:true,demoOnly:true};
  throw Error('Unknown demo action');
 }
 const headers={'Accept':'application/json'};
 if(data!==undefined){headers['Content-Type']='application/json';headers['X-PacketRat-Token']=token;}
 let response;try{response=await fetch('/api/'+route,{method:data!==undefined?'POST':'GET',headers,body:data!==undefined?JSON.stringify(data):undefined,cache:'no-store'})}catch{setEngine('disconnected');throw Error('Local PacketRat service not reachable. Relaunch Launch-PacketRat.bat.')}let payload;try{payload=await response.json()}catch{throw Error('Unexpected response from PowerShell service')}if(!response.ok||payload.ok===false)throw Error(payload.error||payload.message||`Request failed (${response.status})`);return payload;
}
function notify(message,error=false){const el=$('notice');el.textContent=message;el.classList.toggle('error',error);el.classList.toggle('hidden',!message);clearTimeout(noticeTimer);if(message)noticeTimer=setTimeout(()=>el.classList.add('hidden'),8500)}
function show(viewName){if(!names[viewName])return;document.querySelectorAll('.view').forEach(el=>el.classList.toggle('hidden',el.id!==viewName));document.querySelectorAll('.nav[data-view]').forEach(el=>{const on=el.dataset.view===viewName;el.classList.toggle('active',on);if(on)el.setAttribute('aria-current','page');else el.removeAttribute('aria-current')});$('crumb').textContent=names[viewName];document.querySelector('.content')?.scrollTo({top:0,behavior:'instant'});window.scrollTo({top:0,behavior:'instant'});}
function priorityBadge(item){const urgency=['High','Medium','Low'].includes(item.Urgency)?item.Urgency:'Medium';return `<span class="priority ${urgency.toLowerCase()}">${urgency}</span>`}
function itemRow(item,actions=false){
 const key=escapeHtml(item.Key),sub=escapeHtml(item.Subject||'(No subject)'),from=escapeHtml(item.From||'Unknown sender');
 const why=escapeHtml(item.Why||'No reason provided'),status=escapeHtml((item.Status||'open').replace('_',' '));
 const source=item.PriorityOverride?'Manual priority':item.RuleName?'Rule: '+item.RuleName:(item.TriageSource||'AI suggested');
 const label='<span class="source-label">'+escapeHtml(source)+'</span>';
 const title='<button type="button" class="item-title" data-act="open" data-key="'+key+'" title="Open original in Outlook">'+sub+'</button>';
 const levels=['High','Medium','Low'];
 const prioritySelect='<label class="priority-selector">Priority <select data-priority-key="'+key+'" aria-label="Set priority for '+sub+'">'+levels.map(p=>'<option value="'+p+'"'+(item.Urgency===p?' selected':'')+'>'+p+'</option>').join('')+'</select></label>';
 const controls=actions?'<div class="item-actions"><button data-act="open" data-key="'+key+'">Outlook '+icon('external')+'</button><button data-act="draft" data-key="'+key+'">'+icon('draft')+' Draft</button>'+prioritySelect+(item.PriorityOverride?'<button data-act="resetpriority" data-key="'+key+'" title="Restore AI/rule priority">'+icon('reset')+' Reset priority</button>':'')+(item.Status==='done'?'<button data-act="openstatus" data-key="'+key+'">Reopen</button>':'<button data-act="done" data-key="'+key+'">'+icon('check')+' Done</button><button data-act="progress" data-key="'+key+'">In progress</button>')+'<button data-act="dismiss" data-key="'+key+'">Dismiss</button><span class="inbox-actions" role="group" aria-label="Inbox actions"><button data-act="archive" data-key="'+key+'" title="Move the original to the Outlook archive folder">Archive</button><button data-act="markread" data-key="'+key+'" title="Mark the original read in Outlook">Mark read</button><button data-act="categorize" data-key="'+key+'" title="Add an Outlook category to the original">Category</button><button data-act="move" data-key="'+key+'" title="Move the original to an existing Outlook folder">Move</button></span></div>':'';
 return '<article class="item'+(actions?'':' signal-item')+'"'+(actions?'':' role="button" tabindex="0" data-act="open" data-key="'+key+'" aria-label="Open '+sub+' in Outlook"')+'>'+priorityBadge(item)+'<div class="item-body">'+title+'<small title="'+from+' · '+why+'">'+from+' · '+why+' · '+status+' · '+label+'</small></div>'+controls+'</article>';
}
const empty=(caption)=>`<div class="empty"><span class="empty-icon">${icon('inbox',20)}</span>${escapeHtml(caption)}</div>`;
function filteredQueue(){
 let items=store.Checklist.filter(x=>!x.RuleSuppressed&&x.Status!=='dismissed'&&(
  filter==='all'||(filter==='active'&&['open','in_progress'].includes(x.Status))||
  (filter==='high'&&x.Urgency==='High'&&['open','in_progress'].includes(x.Status))||
  x.Status===filter));
 const term=$('queueSearch').value.trim().toLowerCase();
 if(term)items=items.filter(x=>[x.Subject,x.From,x.Why,x.RuleName].some(v=>String(v||'').toLowerCase().includes(term)));
 const priority={High:0,Medium:1,Low:2},sort=$('sortOrder').value;
 return items.sort((a,b)=>sort==='subject'?String(a.Subject).localeCompare(String(b.Subject)):sort==='recent'?String(b.LastSeen||b.CreatedAt||'').localeCompare(String(a.LastSeen||a.CreatedAt||'')):(priority[a.Urgency]??3)-(priority[b.Urgency]??3));
}
function formatInline(value){return escapeHtml(value).replace(/\\*\\*(.+?)\\*\\*/g,'<strong>$1</strong>')}
function renderIntelligence(text){return reportStructure.length?reportUI.renderStructured(reportStructure,reportItems,reportSections):reportUI.renderMarkdown(text,reportItems,reportSections)}
function renderReportExtras(){
 const sources=Array.isArray(reportItems)?reportItems:[];
 const sections=Array.isArray(reportSections)&&reportSections.length?reportSections:reportUI.deriveSections(report);
 const tracked=new Set((store.Checklist||[]).filter(x=>x.Key).map(x=>String(x.Key)));
 const search=$('reportSourceSearch')?.value||'';
 $('reportSources').innerHTML=reportUI.renderSources(sources,tracked,search);
 $('reportSourceCount').textContent=sources.length+' verified';
 const select=$('reportScope'),previous=select.value;
 select.innerHTML='<option value="all">Entire report</option>'+sections.map(section=>
  '<option value="'+escapeHtml(section.Id)+'">'+escapeHtml(section.Title||'Report section')+'</option>').join('');
 select.value=[...select.options].some(o=>o.value===previous)?previous:'all';
 const audit=reportUI.audit(report,sources,sections);
 const warnings=[...new Set([...(reportQuality?.Warnings||[]),...audit.warnings])];
 const quality=$('reportQuality');
 quality.classList.remove('hidden');
 quality.classList.toggle('warning',warnings.length>0);
 const stats=sources.length+' verified messages · '+sections.length+' report sections';
 quality.textContent=warnings.length?stats+' · Review: '+warnings.join(' | '):stats+' · References checked against inbox';
}
async function generateReportFrom(sectionId){
 if(busy){notify('An analysis operation is already in progress.');return;}
 if(!report.trim())return notify('Analyze inbox first to generate from its report.',true);
 const mode=$('reportMode').value,scope=sectionId||$('reportScope').value||'all';
 $('reportScope').value=scope;
 const btn=$('generateReport');btn.disabled=true;btn.textContent='Generating…';
 notify('Generating a new '+mode.toLowerCase()+' from '+(scope==='all'?'the full report':'the selected report section')+'. This will not modify Outlook.');
 try{
  const result=await api('report/generate',{mode,sectionId:scope,profile:$('profile').value});
  generatedReportText=String(result.generated?.Content||'');
  if(!generatedReportText.trim())throw Error('The AI returned an empty follow-up.');
  $('reportGeneratedHeading').textContent=(result.generated?.Mode||mode)+' — '+(result.generated?.Section||'Report');
  $('reportGeneratedText').innerHTML=reportUI.renderMarkdown(generatedReportText,reportItems,[]);
  $('reportGenerated').classList.remove('hidden');
  notify('Report follow-up generated for your review. Nothing has been sent or tracked.');
  $('reportGenerated').scrollIntoView({block:'start',behavior:'smooth'});
 }catch(error){notify(error.message,true)}
 finally{btn.disabled=false;btn.innerHTML=icon('intelligence')+' Generate'}
}
function openDraftForKey(key){
 const source=reportItems.find(x=>x.Key===key),item=(store.Checklist||[]).find(x=>x.Key===key);
 if(!source&&!item)throw Error('This message is not verified in the current report or action queue.');
 draftKey=key;
 $('draftSubject').textContent=item?.Subject||source?.Subject||'No subject';
 $('draftBody').value='';$('draftSubjectSuggested').value='';
 $('draftApplySubject').checked=false;draftVersion=null;
 $('instruction').value='';
 $('draftDialog').showModal();
}
async function handleReportSourceAction(type,key){
 const source=reportItems.find(x=>x.Key===key);
 if(!source)return notify('This reference is not verified in the current inbox scan.',true);
 try{
  if(type==='draft'){openDraftForKey(key);return}
  if(type==='queue'){
   setQueueFilter('all');$('queueSearch').value=source.Subject||'';render();return;
  }
  if(type==='track'){
   const result=await api('report/track',{key,urgency:['High','Medium','Low'].includes(source.Urgency)?source.Urgency:'Medium'});
   store=result.store||store;render();notify('Verified message added to the action queue for human review.');return;
  }
  const result=await api('open',{key});
  notify(result.demoOnly?'Demo only: no Outlook message was opened.':'Original message opened in Outlook.');
 }catch(error){notify(error.message,true)}
}
function render(){const items=store.Checklist||[],dismissed=store.Dismissals||[],suppressed=items.filter(x=>x.RuleSuppressed),visible=items.filter(x=>!x.RuleSuppressed),active=visible.filter(x=>x.Status==='open'||x.Status==='in_progress');$('mOpen').textContent=active.length;$('mHigh').textContent=active.filter(x=>x.Urgency==='High').length;$('mDone').textContent=visible.filter(x=>x.Status==='done').length;$('mDismiss').textContent=dismissed.length+suppressed.length;$('navCount').textContent=active.length;
 $('priorityList').innerHTML=active.length?active.slice().sort((a,b)=>({High:0,Medium:1,Low:2}[a.Urgency]??3)-({High:0,Medium:1,Low:2}[b.Urgency]??3)).slice(0,4).map(x=>itemRow(x)).join(''):empty('Your radar is clear. Run an inbox analysis to discover new actions.');const results=filteredQueue();$('queueTotal').textContent=`${results.length} item${results.length===1?'':'s'}`;$('queue').innerHTML=results.length?results.map(x=>itemRow(x,true)).join(''):empty('No actions match these filters.');$('dismissList').innerHTML=dismissed.length?dismissed.map(x=>`<article class="item"><span class="priority low">Filtered</span><div class="item-body"><strong>${escapeHtml(x.Subject)}</strong><small>${escapeHtml(x.From)} · ${escapeHtml(x.Reason)}</small></div><div class="item-actions"><button data-act="restore" data-key="${escapeHtml(x.Key)}">Restore</button></div></article>`).join(''):empty('No dismissed items. You can dismiss false positives from the action queue.');$('ruleFilteredList').innerHTML=suppressed.length?suppressed.map(x=>
 '<article class="item"><span class="priority low">Rule filter</span><div class="item-body"><strong>'+escapeHtml(x.Subject||'(No subject)')+'</strong><small>'+escapeHtml(x.From||'')+' · '+escapeHtml(x.RuleSuppressedBy||'Matched an exclusion rule')+'</small></div><div class="item-actions"><button data-act="unfilter" data-key="'+escapeHtml(x.Key)+'">Keep in queue</button></div></article>'
 ).join(''):empty('No rule-filtered items in the current action history.');$('reportText').innerHTML=renderIntelligence(report);renderReportExtras();$('brief').textContent=report?report.replace(/^[\s>]+/gm,'').replace(/[#*|]/g,' ').replace(/\s+/g,' ').trim().slice(0,260)+(report.length>260?'…':''):'Run an inbox analysis to generate an actionable briefing using your approved AI provider.';$('lastRun').textContent=lastRun?.GeneratedAt?'Last analyzed '+new Date(lastRun.GeneratedAt).toLocaleString():demo?'Sample data loaded':'Not analyzed yet';$('reportProvider').textContent=lastRun?.Provider||'—';$('reportProfile').textContent=lastRun?.Profile||'—';$('reportCount').textContent=lastRun?.AnalyzedCount??'—';$('engineStatus').textContent=demo?'Sample data, no service':lastRun?'Last analysis available':'Waiting for analysis';}
function updateCredentialPanel(){
 const source=$('credentialSource').value;
 $('manualTokenFields').classList.toggle('hidden',source!=='Manual');
}
function renderCredentialStatus(state){
 if(!state)return;
 credentialDetails=state;
 $('credentialSource').value=state.source==='Manual'?'Manual':'Lazarette';
 updateCredentialPanel();
 const manual=state.manual||{},items=state.lazaretteItems||{};
 const gen=manual.AiEndpoint?'set':'missing',grok=manual.Grok?'set':'missing';
 const line=state.source==='Manual'
   ?'Manual session · AI endpoint '+gen+' · Grok '+grok
   :'Lazarette '+(state.lazaretteDetected?'found':'not detected')+' · AI endpoint: '+(items.AiEndpoint||'ai-endpoint-api')+' · Grok: '+(items.Grok||'grok-api');
 $('credentialStatus').textContent=demo?'Demo mode: no credentials accepted or stored.':line;
 setSession(demo?'Sample data':state.source==='Manual'?'Manual token · this session':'Lazarette credentials');
}
async function applyCredentialSource(){
 if(demo){$('credentialToken').value='';notify('Demo mode never accepts real credentials.',true);return;}
 const source=$('credentialSource').value;
 const profile=$('credentialProfile').value;
 const plain=$('credentialToken').value;
 if(source==='Manual'&&!plain&&!(credentialDetails?.source==='Manual'&&credentialDetails?.manual?.[profile])){
   notify('Enter an approved '+profile+' token before selecting manual mode.',true);return;
 }
 try{
   const result=await api('credentials',{source,profile,token:source==='Manual'?plain:''});
   renderCredentialStatus(result.credentials);
   notify(source==='Manual'?'Manual credential retained in PowerShell memory until exit or removal.':'Managed credential mode selected. Manual tokens cleared.');
 }catch(error){notify(error.message,true);}
 finally{$('credentialToken').value='';}
}
const ruleConditions=[
 ['SecurityAction','Security / mandatory action'],
 ['DirectOrgRequest','Verified direct request from your organization domain'],
 ['DirectRequest','Verified direct request'],
 ['AlreadyReplied','Already replied without new ask'],
 ['AutomatedDigest','Automated digest or newsletter'],
 ['OrgSender','Any sender from your organization domain'],
 ['SenderDomain','Sender domain'],
 ['SenderContains','Sender address contains'],
 ['SubjectContains','Subject contains'],
 ['BodyContains','Message preview contains']
];
function ruleSelect(values,current){
 return values.map(([value,name])=>'<option value="'+escapeHtml(value)+'"'+(value===current?' selected':'')+'>'+escapeHtml(name)+'</option>').join('');
}
function renderRules(){
 const target=$('rulesList');if(!target)return;
 if(!ruleDraft)ruleDraft=(store.Rules?.length?store.Rules:defaultRules).map(x=>({...x}));
 const effects=[['High','High priority'],['Medium','Medium priority'],['Low','Low priority'],['Skip','Exclude suggestion']];
 target.innerHTML=ruleDraft.length?ruleDraft.map((r,i)=>{
   const id=escapeHtml(r.Id),name=escapeHtml(r.Name),value=escapeHtml(r.Value||'');
   return '<div class="rule-row" data-rule-id="'+id+'">'+
    '<div class="rule-row-heading"><label class="rule-toggle"><input type="checkbox" data-rule-field="Enabled"'+(r.Enabled?' checked':'')+'> Enabled</label>'+
    '<span class="rule-order">'+(i+1)+' / '+ruleDraft.length+'</span>'+
    '<button data-rule-move="up" data-rule-id="'+id+'" aria-label="Move rule up"'+(i===0?' disabled':'')+'>'+icon('up')+'</button>'+
    '<button data-rule-move="down" data-rule-id="'+id+'" aria-label="Move rule down"'+(i===ruleDraft.length-1?' disabled':'')+'>'+icon('down')+'</button>'+
    '<button data-rule-remove="'+id+'" aria-label="Remove rule">'+icon('close')+'</button></div>'+
    '<div class="rule-fields"><label>Name<input class="fl-input" data-rule-field="Name" maxlength="90" value="'+name+'"></label>'+
    '<label>When<select class="fl-input" data-rule-field="Match">'+ruleSelect(ruleConditions,r.Match)+'</select></label>'+
    '<label>Match value<input class="fl-input" data-rule-field="Value" maxlength="160" placeholder="For custom matches" value="'+value+'"></label>'+
    '<label>Then<select class="fl-input" data-rule-field="Effect">'+ruleSelect(effects,r.Effect)+'</select></label></div>'+
    '<p class="rule-hint">'+(r.Match==='DirectOrgRequest'?'Requires confirmed recipient match and a request; an organization sender alone is not urgent.':
     r.Match==='SenderDomain'?'Use a domain such as example.org without @.':
     r.Match==='SubjectContains'?'Case-insensitive literal phrase.':
     r.Match==='BodyContains'?'Uses only the limited message preview.':
     r.Match==='AutomatedDigest'?'Excludes routine digests, not known mandatory/security requests.':
     'Rules apply in displayed order. First matching rule wins.')+'</p></div>';
 }).join(''):'<p class="empty">No rules configured. AI classification still runs.</p>';
}
function noteRules(message){$('rulesStatus').textContent=message||'Edits are not active until saved.';}
function setRuleField(node){
 const row=node.closest('[data-rule-id]');if(!row)return;
 const current=ruleDraft?.find(r=>r.Id===row.dataset.ruleId);
 if(!current)return;
 const field=node.dataset.ruleField;
 if(!['Name','Match','Value','Effect','Enabled'].includes(field))return;
 current[field]=field==='Enabled'?node.checked:node.value;
 noteRules('Unsaved changes. Select Save rules to apply them to future inbox analyses.');
}
function addCustomRule(){
 if(!ruleDraft)ruleDraft=[];
 if(ruleDraft.length>=30)return notify('Maximum 30 rules.',true);
 ruleDraft.push({Id:'custom-'+Date.now().toString(36)+'-'+ruleDraft.length,Name:'New custom rule',Enabled:true,Match:'SenderDomain',Value:'example.org',Effect:'Medium'});
 renderRules();noteRules('New rule added. Edit and save it to activate.');
}
async function saveTriageRules(){
 if(!ruleDraft)return;
 for(const r of ruleDraft){
   if(!r.Name?.trim())return notify('Every rule needs a name.',true);
   if(['SenderDomain','SenderContains','SubjectContains','BodyContains'].includes(r.Match)&&!r.Value?.trim())return notify('Provide a match value for '+r.Name,true);
 }
 try{
  const x=await api('rules',{rules:ruleDraft});
  store=x.store||store;ruleDraft=(store.Rules||[]).map(r=>({...r}));
  renderRules();noteRules('Saved. New triage rules apply on your next analysis.');
  notify('Rules saved. Existing manual priorities are preserved.');
 }catch(error){notify(error.message,true)}
}
function saveSettings(){const cfg={profile:$('profile').value,provider:$('provider').value,folder:$('mailFolder').value.trim(),maxEmails:Number($('maxEmails').value),daysBack:Number($('daysBack').value)};if(!Number.isInteger(cfg.maxEmails)||cfg.maxEmails<1||cfg.maxEmails>150||!Number.isInteger(cfg.daysBack)||cfg.daysBack<1||cfg.daysBack>90)throw Error('Choose 1–150 emails and 1–90 days.');try{localStorage.setItem('packetrat-prefs',JSON.stringify(cfg))}catch{}return cfg}
function loadSettings(){try{const cfg=JSON.parse(localStorage.getItem('packetrat-prefs')||'{}');for(const name of ['profile','provider','mailFolder','maxEmails','daysBack'])if(cfg[name]!==undefined)$(name).value=cfg[name]}catch{}}
function bridgePref(){try{return localStorage.getItem('packetrat-bridge-speak')==='1'}catch{return false}}
function bridgeStatus(msg,err){const el=$('bridgeStatus');if(!el)return;el.textContent=msg||'';el.classList.toggle('err',!!err)}
function bridgeMicHelp(error){const n=String((error&&error.name)||'');if(n==='NotAllowedError'||n==='SecurityError')return 'The browser blocked the microphone. Click the permissions icon in the address bar, allow Microphone for this site, then try again.';if(n==='NotFoundError')return 'No microphone was found on this PC.';if(n==='NotReadableError')return 'The microphone is in use by another app.';return (error&&error.message)||'Microphone error.'}
async function bridgeSayText(text){$('bridgeSay').textContent=text;if($('bridgeSpeak').checked&&window.PacketRatVoice){bridgeStatus('Speaking...');try{await window.PacketRatVoice.speak(text);bridgeStatus('')}catch(error){bridgeStatus('The voice could not speak: '+error.message,true)}}}
async function bridgeAsk(question){const q=String(question||'').trim();if(!q)return;$('bridgeProposals').innerHTML='';try{if(window.PacketRatListen&&window.PacketRatListen.intent(q)==='brief'){const b=await api('assist/brief');await bridgeSayText(b.briefing.say);return}const x=await api('assist/ask',{question:q});await bridgeSayText(x.say);$('bridgeProposals').innerHTML=(x.proposals||[]).map((p,i)=>`<button type="button" class="secondary fl-btn fl-btn--secondary" data-proposal="${i}">Confirm: ${escapeHtml(p.action)} ${escapeHtml(p.value||'')} (${escapeHtml(p.key.slice(0,40))})</button>`).join('');$('bridgeProposals').querySelectorAll('[data-proposal]').forEach(b=>b.addEventListener('click',async()=>{const p=x.proposals[Number(b.dataset.proposal)];b.disabled=true;try{await api(p.route.replace('/api/',''),p.body);notify('Done: '+p.action+'.');load()}catch(error){notify(error.message,true);b.disabled=false}}))}catch(error){notify(error.message,true)}}
async function initListen(){const L=window.PacketRatListen;const talk=$('bridgeTalk'),hail=$('bridgeHail'),mic=$('bridgeMic');if(!L||!talk)return;let st=null;try{st=(await api('voice/status')).voice}catch{}if(st&&st.tts&&st.tts.installed&&window.PacketRatPiper){window.PacketRatPiper.install(st.tts);$('bridgeSpeak').disabled=false;$('bridgeSpeak').checked=true;$('bridgeNote').textContent='Speaking with the TalkForge voice '+st.tts.model+'. Everything runs on this PC.'}else if(st&&st.tts&&st.tts.listed>0){$('bridgeNote').textContent+=' TalkForge voice not ready: '+st.tts.note}if(!st||!st.installed){$('bridgeNote').textContent+=' Speech input is not installed (see docs/VOICE.md).';return}talk.disabled=false;hail.disabled=false;L.onMic=on=>{mic.textContent=on?'Microphone OPEN':'Microphone closed'};L.onHail=on=>{hail.checked=on};L.onError=e=>bridgeStatus(e.message,true);L.onHeard=t=>bridgeStatus('Heard: "'+t+'"');L.onStandDown=()=>{bridgeStatus('Standing down. Microphone closed.');bridgeSayText('Standing down.')};const hold=async()=>{bridgeStatus('Opening the microphone...');try{await L.startTalk();talk.textContent='Listening…';bridgeStatus('Listening. Release the button when you are done.')}catch(error){bridgeStatus(bridgeMicHelp(error),true)}};const release=async()=>{talk.textContent='Hold to talk';bridgeStatus('Transcribing (the first time loads the speech model)...');try{const t=await L.stopTalk();if(t){bridgeStatus('Heard: "'+t+'"');$('bridgeQuestion').value=t;bridgeAsk(t)}else bridgeStatus('I did not catch anything. Hold the button while you speak.')}catch(error){bridgeStatus(error.message,true)}};talk.addEventListener('pointerdown',hold);talk.addEventListener('pointerup',release);talk.addEventListener('pointerleave',e=>{if(e.buttons)release()});talk.addEventListener('keydown',e=>{if((e.key===' '||e.key==='Enter')&&!e.repeat){e.preventDefault();hold()}});talk.addEventListener('keyup',e=>{if(e.key===' '||e.key==='Enter')release()});hail.addEventListener('change',async e=>{if(e.target.checked){bridgeStatus('Opening the microphone...');try{await L.setHail(true,async cmd=>{await bridgeSayText('Aye.');if(cmd){$('bridgeQuestion').value=cmd;bridgeAsk(cmd)}else bridgeStatus('At your service. Say your question.')});bridgeStatus('Loading the speech model (the first time can take a minute)...');await L.preload();bridgeStatus('Listening for "Bridge". Say, for example, "Bridge, brief me".')}catch(error){e.target.checked=false;L.setHail(false);bridgeStatus(bridgeMicHelp(error),true)}}else{L.setHail(false);bridgeStatus('Hail off. Microphone closed.')}})}
function initBridge(){const panel=$('bridgePanel');if(!panel)return;const v=window.PacketRatVoice;if(window.PacketRatPiper)window.PacketRatPiper.onStatus=m=>bridgeStatus(m);const can=!!(v&&v.available());$('bridgeSpeak').checked=can&&bridgePref();$('bridgeSpeak').disabled=!can;$('bridgeNote').textContent=can?'Reads with a voice installed on this PC. Cloud voices are never used.':'No speech output is available in this browser, so replies show as text only.';$('bridgeSpeak').addEventListener('change',e=>{try{localStorage.setItem('packetrat-bridge-speak',e.target.checked?'1':'0')}catch{}});$('bridgeAsk').addEventListener('click',()=>bridgeAsk($('bridgeQuestion').value));$('bridgeQuestion').addEventListener('keydown',e=>{if(e.key==='Enter')bridgeAsk(e.target.value)});$('bridgeStop').addEventListener('click',()=>v&&v.stop());$('bridgeBrief').addEventListener('click',async()=>{bridgeStatus('Getting the briefing...');try{const x=await api('assist/brief');await bridgeSayText(x.briefing.say)}catch(error){bridgeStatus(error.message,true)}})}
async function loadLog(){const list=$('logList');if(!list)return;try{const x=await api('log');const v=x.verify;$('logStatus').textContent=(v.ok?'Chain intact: '+v.count+' recorded action'+(v.count===1?'':'s')+'.':'CHAIN BROKEN at line '+v.problemAtLine+': '+v.reason)+' Only action names, message keys and ok/error are recorded, never mail text.';list.innerHTML=(x.entries||[]).slice(-10).reverse().map(e=>`<li><span>${escapeHtml(String(e.time||'').replace('T',' ').slice(0,19))} ${escapeHtml(e.action||'?')}</span><span>${escapeHtml(String(e.key||'').slice(0,28))} ${escapeHtml(e.result||'')}</span></li>`).join('')}catch{$('logStatus').textContent='The action log could not be loaded.'}}
async function verifyLog(){try{const v=(await api('log/verify')).verify;notify(v.ok?'Chain intact ('+v.count+' actions). Tip '+String(v.tip).slice(0,12)+'. Note it outside this PC to catch removal of the newest lines.':'CHAIN BROKEN at line '+v.problemAtLine+': '+v.reason,!v.ok)}catch(error){notify(error.message,true)}}
let statsBusy=false;
async function loadStats(){const panel=$('statsPanel');if(!panel)return;if(demo){panel.classList.add('hidden');return}if(statsBusy)return;statsBusy=true;try{const s=(await api('stats')).stats;$('statsTotal').textContent='≈ '+s.totalMinutes+' min (estimate)';$('statsNote').textContent='Rough estimate: counts of what PacketRat did or prepared, times the minutes assumed in Config/minutes-saved.json. Stored on this PC only; not a score for anyone.';$('statsList').innerHTML=s.actions.map(a=>`<li><span>${escapeHtml(a.label)}</span><span>${a.count} × ${a.minutesEach} min ≈ ${a.minutes} min</span></li>`).join('');panel.classList.remove('hidden')}catch{panel.classList.add('hidden')}finally{statsBusy=false}}
async function load(){try{const x=await api('state');store=x.store||{Checklist:[],Dismissals:[]};report=x.report||'';lastRun=x.lastRun||x.summary||null;reportItems=Array.isArray(x.reportItems)?x.reportItems:[];reportStructure=Array.isArray(x.reportStructure)?x.reportStructure:[];reportSections=Array.isArray(x.reportSections)?x.reportSections:reportUI.deriveSections(report);reportQuality=x.reportQuality||null;if(demo){lastRun={AnalyzedCount:4,Provider:'DEMO',Profile:'Demo'}}renderCredentialStatus(x.credentials||{source:'Lazarette',lazaretteDetected:false,manual:{AiEndpoint:false,Grok:false},lazaretteItems:{}});ruleDraft=(store.Rules||defaultRules).map(r=>({...r}));renderRules();render();loadStats();loadLog();setEngine(demo?'demo':'running');}catch(error){notify(error.message,true);render()}}
function setQueueFilter(next){
 filter=next;
 document.querySelectorAll('[data-filter]').forEach(b=>b.classList.toggle('active',b.dataset.filter===filter));
 render();show('triage');
}
function initializeSingleDraft(draft){
 if(!draft||draft.Version!=='PACKETRAT_DRAFT_V1'||typeof draft.Subject!=='string'||typeof draft.Body!=='string'){
  throw Error('AI draft response did not match PacketRat DRAFT_V1 protocol.');
 }
 $('draftSubjectSuggested').value=draft.Subject;
 $('draftBody').value=draft.Body;
 draftVersion=draft.Version;
}
function setBusy(flag,label){busy=flag;const button=$('analyze');button.disabled=flag;button.innerHTML=flag?icon('loading')+' Analyzing…':icon('analyze')+' Analyze inbox';if(!demo&&!sessionEnded&&$('engineState')?.classList.contains('engine-disconnected')===false)setEngine(flag?'busy':'running');$('engineStatus').textContent=flag?label||'Running analysis':demo?'Sample data, no service':lastRun?'Last analysis available':'Waiting for analysis'}
document.querySelectorAll('[data-view]').forEach(el=>el.addEventListener('click',()=>show(el.dataset.view)));document.querySelectorAll('[data-go]').forEach(el=>el.addEventListener('click',()=>show(el.dataset.go)));document.querySelectorAll('[data-filter]').forEach(el=>el.addEventListener('click',()=>setQueueFilter(el.dataset.filter)));$('queueSearch').addEventListener('input',render);$('sortOrder').addEventListener('change',render);
$('reportSourceSearch').addEventListener('input',()=>renderReportExtras());
$('generateReport').addEventListener('click',()=>generateReportFrom());
$('copyGenerated').addEventListener('click',()=>copy(generatedReportText));
$('closeGenerated').addEventListener('click',()=>$('reportGenerated').classList.add('hidden'));
document.addEventListener('click',event=>{
 const section=event.target.closest('[data-report-generate-section]');
 if(section){generateReportFrom(section.dataset.reportGenerateSection);return}
 const node=event.target.closest('[data-report-open-index],[data-report-open],[data-report-draft],[data-report-track],[data-report-queue]');
 if(!node||busy)return;
 if(node.hasAttribute('data-report-open-index')){
  const index=Number(node.dataset.reportOpenIndex);
  const source=reportItems.find(x=>Number(x.Index)===index);
  if(!source){notify('This report reference does not match a verified email.',true);return}
  handleReportSourceAction('open',source.Key);return;
 }
 if(node.hasAttribute('data-report-open'))handleReportSourceAction('open',node.dataset.reportOpen);
 else if(node.hasAttribute('data-report-draft'))handleReportSourceAction('draft',node.dataset.reportDraft);
 else if(node.hasAttribute('data-report-track'))handleReportSourceAction('track',node.dataset.reportTrack);
 else if(node.hasAttribute('data-report-queue'))handleReportSourceAction('queue',node.dataset.reportQueue);
});
document.addEventListener('keydown',event=>{
 if((event.key==='Enter'||event.key===' ')&&event.target.matches('tr[data-report-open-index]')){
  event.preventDefault();event.target.click();
 }
});
document.querySelectorAll('[data-metric]').forEach(el=>el.addEventListener('click',()=>{const metric=el.dataset.metric;if(metric==='dismiss')show('dismissals');else setQueueFilter(metric==='high'?'high':metric==='done'?'done':'active')}));
document.addEventListener('change',async event=>{
 const input=event.target.closest('[data-priority-key]');if(!input||busy)return;
 const key=input.dataset.priorityKey,urgency=input.value;
 input.disabled=true;
 try{const result=await api('priority',{key,urgency});store=result.store||store;render();notify('Priority updated to '+urgency+'. Manual choice will survive reanalysis.')}
 catch(error){notify(error.message,true);render()}
 finally{input.disabled=false}
});
document.addEventListener('keydown',event=>{
 const row=event.target.matches('.signal-item')?event.target:null;
 if(row&&(event.key==='Enter'||event.key===' ')){event.preventDefault();row.click()}
});

$('analyze').addEventListener('click',async()=>{if(busy)return;let cfg;try{cfg=saveSettings()}catch(error){notify(error.message,true);show('settings');return}setBusy(true,'Scanning inbox');notify(demo?'Running sample analysis. No real email is accessed.':'Analyzing Outlook and calling the configured AI provider. The local engine will be busy until this operation completes.');try{const x=await api('analyze',cfg);store=x.store||store;report=x.report||'';reportItems=Array.isArray(x.reportItems)?x.reportItems:[];reportStructure=Array.isArray(x.reportStructure)?x.reportStructure:[];reportSections=Array.isArray(x.reportSections)?x.reportSections:reportUI.deriveSections(report);reportQuality=x.reportQuality||null;generatedReportText='';$('reportGenerated').classList.add('hidden');lastRun={...(x.summary||{}),...(x.metadata||{}),GeneratedAt:new Date().toISOString()};if(demo)demoPersist();render();loadStats();show('report');notify('Analysis complete. Review suggested actions before acting.')}catch(error){notify(error.message,true)}finally{setBusy(false)}});
document.addEventListener('click',async event=>{const button=event.target.closest('[data-act]');if(!button||busy)return;const key=button.dataset.key,act=button.dataset.act;try{if(act==='draft'){openDraftForKey(key);return}button.disabled=true;if(act==='dismiss'){const reason=window.prompt('Why should this message be excluded from future action queues?','No action required / false positive');if(reason===null)return;store=(await api('dismiss',{key,reason:reason.trim().slice(0,300)})).store}else if(act==='restore')store=(await api('restore',{key})).store;else if(act==='unfilter'){const original=store.Checklist.find(x=>x.Key===key);store=(await api('priority',{key,urgency:original?.Urgency||'Medium'})).store;}else if(act==='resetpriority')store=(await api('priority/reset',{key})).store;else if(['done','progress','openstatus'].includes(act))store=(await api('status',{key,status:act==='done'?'done':act==='progress'?'in_progress':'open'})).store;else if(act==='archive'){if(!window.confirm('Move this message to the Outlook archive folder and remove it from the queue? You can move it back in Outlook.'))return;const r=await api('item/archive',{key});store=r.store||store;render();notify(r.demoOnly?'Demo mode: nothing was moved in Outlook.':'Message archived in Outlook.');return}else if(act==='markread'){const r=await api('item/mark-read',{key,unread:false});notify(r.demoOnly?'Demo mode: nothing was changed in Outlook.':'Message marked read in Outlook.');return}else if(act==='categorize'){const category=window.prompt('Outlook category to add to this message (no semicolons):','PacketRat');if(category===null)return;const r=await api('item/categorize',{key,category:category.trim().slice(0,255)});notify(r.demoOnly?'Demo mode: nothing was changed in Outlook.':'Category added in Outlook.');return}else if(act==='move'){const folder=window.prompt('Name of an existing Outlook folder to move this message to:','');if(folder===null||!folder.trim())return;if(!window.confirm('Move this message to the Outlook folder "'+folder.trim()+'"? You can move it back in Outlook.'))return;const r=await api('item/move',{key,folder:folder.trim().slice(0,256)});notify(r.demoOnly?'Demo mode: nothing was moved in Outlook.':'Message moved in Outlook.');return}else if(act==='open'){const result=await api('open',{key});notify(result.demoOnly?'Demo mode: no real Outlook message is available.':'Message opened in Outlook.');return}render();notify('Action updated.')}catch(error){notify(error.message,true)}finally{button.disabled=false}});
$('closeDialog').addEventListener('click',()=>$('draftDialog').close());$('generateDraft').addEventListener('click',async()=>{const button=$('generateDraft');button.disabled=true;button.textContent='Generating…';try{const x=await api('draft',{key:draftKey,profile:$('profile').value,instruction:$('instruction').value.slice(0,2000)});initializeSingleDraft(x.draft);notify('One draft is ready. Outlook will insert its configured reply signature; nothing has been sent.')}catch(error){notify(error.message,true)}finally{button.disabled=false;button.innerHTML=icon('intelligence')+' Generate draft'}});async function copy(text){try{await navigator.clipboard.writeText(text);notify('Copied to clipboard.')}catch{notify('Clipboard unavailable. Select and copy the text manually.',true)}}$('copyDraft').addEventListener('click',()=>copy($('draftBody').value));$('copyReport').addEventListener('click',()=>copy(reportUI.normalizeText(report)));$('openDraft').addEventListener('click',async()=>{const body=$('draftBody').value.trim();if(!body)return notify('Enter or generate a draft first.',true);try{const x=await api('open-draft',{key:draftKey,body,subject:$('draftSubjectSuggested').value.trim(),applySubject:$('draftApplySubject').checked});notify(x.demoOnly?'Demo mode: no Outlook message was opened.':'Reply opened in Outlook. You must manually review and send it.')}catch(error){notify(error.message,true)}});
$('addRule').addEventListener('click',addCustomRule);
$('resetRules').addEventListener('click',()=>{ruleDraft=defaultRules.map(r=>({...r}));renderRules();noteRules('Suggested defaults restored in editor; click Save rules to apply.')});
$('saveRules').addEventListener('click',saveTriageRules);
document.addEventListener('change',e=>{if(e.target.matches('[data-rule-field]'))setRuleField(e.target)});
document.addEventListener('input',e=>{if(e.target.matches('input[data-rule-field]'))setRuleField(e.target)});
document.addEventListener('click',e=>{
 const del=e.target.closest('[data-rule-remove]'),move=e.target.closest('[data-rule-move]');
 if(del){ruleDraft=ruleDraft.filter(x=>x.Id!==del.dataset.ruleRemove);renderRules();noteRules('Rule removed in editor; save to activate.');return}
 if(move){const i=ruleDraft.findIndex(x=>x.Id===move.dataset.ruleId),j=i+(move.dataset.ruleMove==='up'?-1:1);
  if(i<0||j<0||j>=ruleDraft.length)return;
  [ruleDraft[i],ruleDraft[j]]=[ruleDraft[j],ruleDraft[i]];renderRules();noteRules('Rule order changed; save to activate.');
 }
});
$('credentialSource').addEventListener('change',updateCredentialPanel);
$('applyCredentials').addEventListener('click',applyCredentialSource);
$('checkCredentials').addEventListener('click',async()=>{
 if(demo){notify('Demo mode uses sample data and does not test credentials.');return;}
 try{
  const profile=$('credentialProfile').value;
  const result=await api('credentials/check',{profile});
  notify(result.credentialAvailable===false?result.profile+': '+result.note:result.profile+' token was resolved locally. Provider connectivity is not yet verified.');
 }catch(error){notify(error.message,true);}
});
$('clearCredentials').addEventListener('click',async()=>{
 if(demo){notify('Demo mode does not store credentials.');return;}
 try{
   const result=await api('credentials/clear',{});
   renderCredentialStatus(result.credentials);
   $('credentialToken').value='';
   notify('Manual credentials cleared from this PowerShell session.');
 }catch(error){notify(error.message,true);}
});
$('saveSettings').addEventListener('click',()=>{try{saveSettings();notify('Preferences saved in this browser.')}catch(error){notify(error.message,true)}});$('exitDemo').addEventListener('click',()=>{location.href=location.pathname});
document.addEventListener('keydown',event=>{if(event.key==='Escape'&&$('draftDialog').open){event.preventDefault();$('draftDialog').close()}if((event.ctrlKey||event.metaKey)&&event.key.toLowerCase()==='k'){event.preventDefault();show('triage');$('queueSearch').focus()}});
/* Lifecycle: this tab owns the local PowerShell service. Heartbeat every 5 s; on pagehide a
   sendBeacon "leaving" signal (it cannot set headers, so the nonce rides in the JSON body of
   /api/heartbeat only). The service stops itself once no PacketRat tab is alive. */
const tabId=(()=>{try{return crypto.randomUUID()}catch{return 'tab-'+Date.now().toString(36)+'-'+Math.random().toString(36).slice(2,10)}})();
let sessionEnded=false;
function startHeartbeat(intervalMs=5000){
 if(!/^[0-9a-f]{32}$/.test(token))return ()=>{};
 const send=leaving=>{if(sessionEnded)return;try{fetch('/api/heartbeat',{method:'POST',headers:{'Content-Type':'application/json','X-PacketRat-Token':token},body:JSON.stringify({tab:tabId,leaving}),keepalive:true,cache:'no-store'}).then(r=>{if(!sessionEnded&&!leaving&&!busy)setEngine(r.ok?'running':'disconnected')}).catch(()=>{if(!sessionEnded&&!leaving)setEngine('disconnected')})}catch{}};
 send(false);
 const timer=setInterval(()=>send(false),intervalMs);
 const onHide=()=>{if(sessionEnded)return;let sent=false;try{if(navigator.sendBeacon)sent=navigator.sendBeacon('/api/heartbeat',new Blob([JSON.stringify({tab:tabId,leaving:true,token})],{type:'application/json'}))}catch{sent=false}if(!sent)send(true)};
 const onShow=event=>{if(event.persisted)send(false)};
 const onVisible=()=>{if(document.visibilityState==='visible')send(false)};
 window.addEventListener('pagehide',onHide);window.addEventListener('pageshow',onShow);document.addEventListener('visibilitychange',onVisible);
 return ()=>{clearInterval(timer);window.removeEventListener('pagehide',onHide);window.removeEventListener('pageshow',onShow);document.removeEventListener('visibilitychange',onVisible)};
}
let stopHeartbeat=()=>{};
function showSessionEnded(){sessionEnded=true;stopHeartbeat();setEngine('stopped');$('sessionEnded').classList.remove('hidden');document.title='PacketRat | Session ended'}
$('endSession').addEventListener('click',async()=>{
 if(demo&&!/^[0-9a-f]{32}$/.test(token)){notify('Demo mode: there is no local service to stop.');return}
 if(busy){notify('Wait for the current analysis to finish before ending the session.',true);return}
 if(!window.confirm('End this PacketRat session? The local PowerShell service stops; unsaved draft text in this tab is lost.'))return;
 try{await fetch('/api/session/stop',{method:'POST',headers:{'Content-Type':'application/json','X-PacketRat-Token':token},body:'{}',cache:'no-store'});showSessionEnded()}catch{notify('Local PacketRat service not reachable; it may already have stopped.',true)}
});
stopHeartbeat=startHeartbeat();
function tick(){$('clock').textContent=new Date().toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'})}tick();setInterval(tick,30000);loadSettings();$('boundAddress').textContent=demo?'Offline demo · no engine':location.host||'—';setEngine(demo?'demo':'connecting');if(demo){$('demoBanner').classList.remove('hidden');setSession('Sample data')}
if(!demo)fetch('/api/health',{cache:'no-store'}).then(r=>r.json()).then(x=>{if(x&&x.version)$('appVersion').textContent='PacketRat '+x.version}).catch(()=>{});
if($('verifyLog'))$('verifyLog').addEventListener('click',verifyLog);initBridge();initListen();
load();
