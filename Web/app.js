'use strict';
/* MailHawk browser client: no secrets, external libraries, or automatic email sending. */
const $=id=>document.getElementById(id);
const demo=new URLSearchParams(location.search).get('demo')==='1'||document.documentElement.dataset.demo==='1';
const token=document.querySelector('meta[name="mailhawk-token"]')?.content||'';
const names={overview:'Overview',triage:'Action queue',report:'AI intelligence',dismissals:'Dismissal memory',settings:'Configuration'};
let store={Checklist:[],Dismissals:[]},report='',lastRun=null,filter='all',draftKey='',busy=false,noticeTimer=null;
let ruleDraft=null,draftAlternatives=[],activeDraftId='A';
let reportItems=[],reportSections=[],reportQuality=null,generatedReportText='';
const reportUI=window.MailHawkReport;
let credentialDetails=null;
const escapeHtml=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const defaultRules=[
 {Id:'security',Name:'Security / mandatory action',Enabled:true,Match:'SecurityAction',Value:'',Effect:'High'},
 {Id:'directmil',Name:'Direct .mil request',Enabled:true,Match:'DirectMilRequest',Value:'',Effect:'High'},
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
Three pending requests. This is test data, not a live GenAI response.`;
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
function demoDefault(){return {Checklist:fakeItems.map(x=>({...x})),Dismissals:[],Rules:defaultRules.map(x=>({...x})),UpdatedAt:new Date().toISOString()};}
function demoStore(){try{const x=JSON.parse(sessionStorage.getItem('mailhawk-demo-store')||'null');return x&&Array.isArray(x.Checklist)&&Array.isArray(x.Dismissals)?{...x,Rules:Array.isArray(x.Rules)?x.Rules:defaultRules.map(r=>({...r}))}:demoDefault()}catch{return demoDefault()}}
function demoPersist(){sessionStorage.setItem('mailhawk-demo-store',JSON.stringify(store));}
async function api(route,data){
 if(demo){await new Promise(resolve=>setTimeout(resolve,140));if(route==='state')return {ok:true,store:demoStore(),report:demoReport,reportItems:demoReportItems(),reportSections:reportUI.deriveSections(demoReport),reportQuality:{Warnings:[],VerifiedSources:4,HasStructuredReferences:true},lastRun:{AnalyzedCount:4,Provider:'DEMO'},metadata:{profile:'Demo',model:'Sample'}};
  if(route==='credentials/status')return {ok:true,credentials:{source:'ARC',manual:{GenAi:false,Grok:false},arcDetected:false,arcItems:{GenAi:'genapi',Grok:'advana-api'}}};
   if(route==='credentials'||route==='credentials/clear')return {ok:true,credentials:{source:data?.source||'ARC',manual:{GenAi:false,Grok:false},arcDetected:false,arcItems:{GenAi:'genapi',Grok:'advana-api'}}};
   if(route==='analyze'){store=demoStore();demoPersist();return {ok:true,store,report:demoReport,reportItems:demoReportItems(),reportSections:reportUI.deriveSections(demoReport),reportQuality:{Warnings:[],VerifiedSources:4,HasStructuredReferences:true},summary:{AnalyzedCount:4,Provider:'DEMO'},metadata:{profile:'Demo',model:'Sample'}}}
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
  if(route==='draft'){const a='Thank you for the update. I will review the details and follow up with you shortly. Please let me know if there is a specific deadline I should prioritize.\n\nBest regards';const b='I appreciate you reaching out. I can take a closer look and would welcome any additional context or timing requirements you would like me to consider.\n\nThank you.';return {ok:true,draft:{Draft:a,Options:[{Id:'A',Label:'Concise',Body:a},{Id:'B',Label:'Collaborative',Body:b}],Profile:'Demo',OutputTokenBudget:20000}}}
  if(route==='open'||route==='open-draft')return {ok:true,demoOnly:true};
  throw Error('Unknown demo action');
 }
 const headers={'Accept':'application/json'};
 if(data!==undefined){headers['Content-Type']='application/json';headers['X-MailHawk-Token']=token;}
 let response;try{response=await fetch('/api/'+route,{method:data!==undefined?'POST':'GET',headers,body:data!==undefined?JSON.stringify(data):undefined,cache:'no-store'})}catch{throw Error('Local MailHawk service not reachable. Relaunch MailHawk.bat.')}let payload;try{payload=await response.json()}catch{throw Error('Unexpected response from PowerShell service')}if(!response.ok||payload.ok===false)throw Error(payload.error||payload.message||`Request failed (${response.status})`);return payload;
}
function notify(message,error=false){const el=$('notice');el.textContent=message;el.classList.toggle('error',error);el.classList.toggle('hidden',!message);clearTimeout(noticeTimer);if(message)noticeTimer=setTimeout(()=>el.classList.add('hidden'),8500)}
function show(viewName){if(!names[viewName])return;document.querySelectorAll('.view').forEach(el=>el.classList.toggle('hidden',el.id!==viewName));document.querySelectorAll('.nav').forEach(el=>el.classList.toggle('active',el.dataset.view===viewName));$('crumb').textContent=names[viewName];window.scrollTo({top:0,behavior:'instant'});}
function priorityBadge(item){const urgency=['High','Medium','Low'].includes(item.Urgency)?item.Urgency:'Medium';return `<span class="priority ${urgency.toLowerCase()}">${urgency}</span>`}
function itemRow(item,actions=false){
 const key=escapeHtml(item.Key),sub=escapeHtml(item.Subject||'(No subject)'),from=escapeHtml(item.From||'Unknown sender');
 const why=escapeHtml(item.Why||'No reason provided'),status=escapeHtml((item.Status||'open').replace('_',' '));
 const source=item.PriorityOverride?'Manual priority':item.RuleName?'Rule: '+item.RuleName:(item.TriageSource||'AI suggested');
 const label='<span class="source-label">'+escapeHtml(source)+'</span>';
 const title='<button type="button" class="item-title" data-act="open" data-key="'+key+'" title="Open original in Outlook">'+sub+'</button>';
 const levels=['High','Medium','Low'];
 const prioritySelect='<label class="priority-selector">Priority <select data-priority-key="'+key+'" aria-label="Set priority for '+sub+'">'+levels.map(p=>'<option value="'+p+'"'+(item.Urgency===p?' selected':'')+'>'+p+'</option>').join('')+'</select></label>';
 const controls=actions?'<div class="item-actions"><button data-act="open" data-key="'+key+'">Outlook ↗</button><button data-act="draft" data-key="'+key+'">✧ Draft</button>'+prioritySelect+(item.PriorityOverride?'<button data-act="resetpriority" data-key="'+key+'" title="Restore AI/rule priority">Reset priority</button>':'')+(item.Status==='done'?'<button data-act="openstatus" data-key="'+key+'">Reopen</button>':'<button data-act="done" data-key="'+key+'">✓ Done</button><button data-act="progress" data-key="'+key+'">In progress</button>')+'<button data-act="dismiss" data-key="'+key+'">Dismiss</button></div>':'';
 return '<article class="item'+(actions?'':' signal-item')+'"'+(actions?'':' role="button" tabindex="0" data-act="open" data-key="'+key+'" aria-label="Open '+sub+' in Outlook"')+'>'+priorityBadge(item)+'<div class="item-body">'+title+'<small title="'+from+' · '+why+'">'+from+' · '+why+' · '+status+' · '+label+'</small></div>'+controls+'</article>';
}
const empty=(caption)=>`<div class="empty"><span class="empty-icon">◎</span>${escapeHtml(caption)}</div>`;
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
function renderIntelligence(text){return reportUI.renderMarkdown(text,reportItems,reportSections)}
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
 finally{btn.disabled=false;btn.textContent='✧ Generate'}
}
function openDraftForKey(key){
 const source=reportItems.find(x=>x.Key===key),item=(store.Checklist||[]).find(x=>x.Key===key);
 if(!source&&!item)throw Error('This message is not verified in the current report or action queue.');
 draftKey=key;
 $('draftSubject').textContent=item?.Subject||source?.Subject||'No subject';
 $('draftBody').value='';draftAlternatives=[];activeDraftId='A';
 $('draftOptions').innerHTML='';$('draftOptions').classList.add('hidden');
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
 $('credentialSource').value=state.source==='Manual'?'Manual':'ARC';
 updateCredentialPanel();
 const manual=state.manual||{},arc=state.arcItems||{};
 const gen=manual.GenAi?'set':'missing',grok=manual.Grok?'set':'missing';
 const line=state.source==='Manual'
   ?'Manual session · GenAi '+gen+' · Grok '+grok
   :'ARC '+(state.arcDetected?'found':'not detected')+' · GenAi: '+(arc.GenAi||'genapi')+' · Grok: '+(arc.Grok||'advana-api');
 $('credentialStatus').textContent=demo?'Demo mode: no credentials accepted or stored.':line;
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
 ['DirectMilRequest','Verified direct .mil request'],
 ['DirectRequest','Verified direct request'],
 ['AlreadyReplied','Already replied without new ask'],
 ['AutomatedDigest','Automated digest or newsletter'],
 ['MilSender','Any .mil sender'],
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
    '<button data-rule-move="up" data-rule-id="'+id+'" aria-label="Move rule up"'+(i===0?' disabled':'')+'>↑</button>'+
    '<button data-rule-move="down" data-rule-id="'+id+'" aria-label="Move rule down"'+(i===ruleDraft.length-1?' disabled':'')+'>↓</button>'+
    '<button data-rule-remove="'+id+'" aria-label="Remove rule">✕</button></div>'+
    '<div class="rule-fields"><label>Name<input data-rule-field="Name" maxlength="90" value="'+name+'"></label>'+
    '<label>When<select data-rule-field="Match">'+ruleSelect(ruleConditions,r.Match)+'</select></label>'+
    '<label>Match value<input data-rule-field="Value" maxlength="160" placeholder="For custom matches" value="'+value+'"></label>'+
    '<label>Then<select data-rule-field="Effect">'+ruleSelect(effects,r.Effect)+'</select></label></div>'+
    '<p class="rule-hint">'+(r.Match==='DirectMilRequest'?'Requires confirmed recipient match and a request; .mil alone is not urgent.':
     r.Match==='SenderDomain'?'Use a domain such as navy.mil without @.':
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
 ruleDraft.push({Id:'custom-'+Date.now().toString(36)+'-'+ruleDraft.length,Name:'New custom rule',Enabled:true,Match:'SenderDomain',Value:'navy.mil',Effect:'Medium'});
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
function saveSettings(){const cfg={profile:$('profile').value,provider:$('provider').value,maxEmails:Number($('maxEmails').value),daysBack:Number($('daysBack').value)};if(!Number.isInteger(cfg.maxEmails)||cfg.maxEmails<1||cfg.maxEmails>150||!Number.isInteger(cfg.daysBack)||cfg.daysBack<1||cfg.daysBack>90)throw Error('Choose 1–150 emails and 1–90 days.');try{localStorage.setItem('mailhawk-prefs',JSON.stringify(cfg))}catch{}return cfg}
function loadSettings(){try{const cfg=JSON.parse(localStorage.getItem('mailhawk-prefs')||'{}');for(const name of ['profile','provider','maxEmails','daysBack'])if(cfg[name]!==undefined)$(name).value=cfg[name]}catch{}}
async function load(){try{const x=await api('state');store=x.store||{Checklist:[],Dismissals:[]};report=x.report||'';lastRun=x.lastRun||x.summary||null;reportItems=Array.isArray(x.reportItems)?x.reportItems:[];reportSections=Array.isArray(x.reportSections)?x.reportSections:reportUI.deriveSections(report);reportQuality=x.reportQuality||null;if(demo){lastRun={AnalyzedCount:4,Provider:'DEMO',Profile:'Demo'}}renderCredentialStatus(x.credentials||{source:'ARC',arcDetected:false,manual:{GenAi:false,Grok:false},arcItems:{}});ruleDraft=(store.Rules||defaultRules).map(r=>({...r}));renderRules();render();$('connectionStatus').innerHTML=`<span class="status-dot"></span> ${demo?'Demo · Offline':'Local connection'}`;}catch(error){notify(error.message,true);render()}}
function setQueueFilter(next){
 filter=next;
 document.querySelectorAll('[data-filter]').forEach(b=>b.classList.toggle('active',b.dataset.filter===filter));
 render();show('triage');
}
function saveDraftSelection(){
 const current=draftAlternatives.find(x=>x.Id===activeDraftId);
 if(current)current.Body=$('draftBody').value;
}
function selectDraftOption(id){
 const option=draftAlternatives.find(x=>x.Id===id);if(!option)return;
 saveDraftSelection();activeDraftId=id;
 $('draftOptions').querySelectorAll('[data-draft-option]').forEach(x=>{
  const selected=x.dataset.draftOption===id;x.classList.toggle('selected',selected);x.setAttribute('aria-selected',String(selected));
 });
 $('draftBody').value=option.Body;
}
function initializeDraftAlternatives(draft){
 draftAlternatives=(Array.isArray(draft?.Options)&&draft.Options.length?draft.Options:[{Id:'A',Label:'Suggested response',Body:draft?.Draft||''}])
   .slice(0,3).map((x,i)=>({Id:['A','B','C'][i],Label:String(x.Label||'Response '+['A','B','C'][i]),Body:String(x.Body||'')}));
 activeDraftId='';const container=$('draftOptions');container.innerHTML=draftAlternatives.map(x=>
  '<button class="draft-option" type="button" role="tab" aria-selected="false" data-draft-option="'+escapeHtml(x.Id)+'"><strong>Response '+escapeHtml(x.Id)+'</strong><span>'+escapeHtml(x.Label)+'</span></button>'
 ).join('');
 container.classList.toggle('hidden',draftAlternatives.length<=1);
 selectDraftOption('A');
}
function setBusy(flag,label){busy=flag;const button=$('analyze');button.disabled=flag;button.innerHTML=flag?'<span>◌</span> Analyzing…':'<span>✦</span> Analyze inbox <span class="button-arrow">↗</span>';$('engineStatus').textContent=flag?label||'Running analysis':demo?'Sample data, no service':lastRun?'Last analysis available':'Waiting for analysis'}
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
document.addEventListener('click',event=>{
 const tab=event.target.closest('[data-draft-option]');if(tab)selectDraftOption(tab.dataset.draftOption);
});
$('analyze').addEventListener('click',async()=>{if(busy)return;let cfg;try{cfg=saveSettings()}catch(error){notify(error.message,true);show('settings');return}setBusy(true,'Scanning inbox');notify(demo?'Running sample analysis. No real email is accessed.':'Analyzing Outlook and calling the configured AI provider. The local engine will be busy until this operation completes.');try{const x=await api('analyze',cfg);store=x.store||store;report=x.report||'';reportItems=Array.isArray(x.reportItems)?x.reportItems:[];reportSections=Array.isArray(x.reportSections)?x.reportSections:reportUI.deriveSections(report);reportQuality=x.reportQuality||null;generatedReportText='';$('reportGenerated').classList.add('hidden');lastRun={...(x.summary||{}),...(x.metadata||{}),GeneratedAt:new Date().toISOString()};if(demo)demoPersist();render();show('report');notify('Analysis complete. Review suggested actions before acting.')}catch(error){notify(error.message,true)}finally{setBusy(false)}});
document.addEventListener('click',async event=>{const button=event.target.closest('[data-act]');if(!button||busy)return;const key=button.dataset.key,act=button.dataset.act;try{if(act==='draft'){openDraftForKey(key);return}button.disabled=true;if(act==='dismiss'){const reason=window.prompt('Why should this message be excluded from future action queues?','No action required / false positive');if(reason===null)return;store=(await api('dismiss',{key,reason:reason.trim().slice(0,300)})).store}else if(act==='restore')store=(await api('restore',{key})).store;else if(act==='unfilter'){const original=store.Checklist.find(x=>x.Key===key);store=(await api('priority',{key,urgency:original?.Urgency||'Medium'})).store;}else if(act==='resetpriority')store=(await api('priority/reset',{key})).store;else if(['done','progress','openstatus'].includes(act))store=(await api('status',{key,status:act==='done'?'done':act==='progress'?'in_progress':'open'})).store;else if(act==='open'){const result=await api('open',{key});notify(result.demoOnly?'Demo mode: no real Outlook message is available.':'Message opened in Outlook.');return}render();notify('Action updated.')}catch(error){notify(error.message,true)}finally{button.disabled=false}});
$('closeDialog').addEventListener('click',()=>$('draftDialog').close());$('generateDraft').addEventListener('click',async()=>{const button=$('generateDraft');button.disabled=true;button.textContent='Generating…';try{const x=await api('draft',{key:draftKey,profile:$('profile').value,instruction:$('instruction').value.slice(0,2000)});initializeDraftAlternatives(x.draft);notify('Draft alternatives ready. Select and edit Response A or B; nothing has been sent.')}catch(error){notify(error.message,true)}finally{button.disabled=false;button.textContent='✦ Generate draft'}});async function copy(text){try{await navigator.clipboard.writeText(text);notify('Copied to clipboard.')}catch{notify('Clipboard unavailable. Select and copy the text manually.',true)}}$('copyDraft').addEventListener('click',()=>copy($('draftBody').value));$('copyReport').addEventListener('click',()=>copy(reportUI.normalizeText(report)));$('openDraft').addEventListener('click',async()=>{const body=$('draftBody').value.trim();if(!body)return notify('Enter or generate a draft first.',true);try{const x=await api('open-draft',{key:draftKey,body});notify(x.demoOnly?'Demo mode: no Outlook message was opened.':'Reply opened in Outlook. You must manually review and send it.')}catch(error){notify(error.message,true)}});
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
  notify(result.profile+' token was resolved locally. Provider connectivity is not yet verified.');
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
document.addEventListener('keydown',event=>{if(event.key==='Escape'&&$('draftDialog').open)$('draftDialog').close();if((event.ctrlKey||event.metaKey)&&event.key.toLowerCase()==='k'){event.preventDefault();show('triage');$('queueSearch').focus()}});
function tick(){$('clock').textContent=new Date().toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'})}tick();setInterval(tick,30000);loadSettings();if(demo){$('demoBanner').classList.remove('hidden');$('modeLabel').textContent='Demo mode';}load();
