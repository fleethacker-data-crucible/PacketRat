/* PacketRat report presentation: pure browser helpers, no network calls or credentials. */
(function(root){
 'use strict';
 // Lucide icons from icons.js when present (browser); plain text elsewhere (Node tests).
 const icon=name=>{try{return root.PacketRatIcons?root.PacketRatIcons.svg(name,16):''}catch{return ''}};
 const escapeHtml=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const replacements=[
  ['Ã¢â‚¬â„¢','’'],['Ã¢â‚¬Ëœ','‘'],['Ã¢â‚¬Å“','“'],
  ['Ã¢â‚¬Â','”'],['Ã¢â‚¬â€œ','–'],['Ã¢â‚¬â€','—'],
  ['Ã¢â‚¬Â¢','•'],['Ã¢â‚¬Â¦','…'],
  ['â€™','’'],['â€˜','‘'],['â€œ','“'],['â€','”'],['â€“','–'],['â€”','—'],
  ['â€¢','•'],['â€¦','…'],['Â ',' '],['Â·','·'],['Â©','©'],['Â®','®'],
  ['Ã©','é'],['Ã¨','è'],['Ã±','ñ'],['Ã¼','ü'],['Ã¶','ö'],
  ['Ã¤','ä'],['Ã³','ó'],['Ã­','í'],['ï»¿',''],['â„¢','™']
 ];
 function normalizeText(input){
  let s=String(input??'');
  s=s.replace(/@@@PACKETRAT_JSON_BEGIN@@@[\s\S]*?@@@PACKETRAT_JSON_END@@@/g,'');
  s=s.replace(/^\uFEFF/g,'').replace(/[\u200B-\u200F\u202A-\u202E\u00AD]/g,'').replace(/\u00A0/g,' ');
  for(const [from,to] of replacements)s=s.split(from).join(to);
  s=s.replace(/\x1B\[[0-9;]*[A-Za-z]/g,'').replace(/[\x00-\x08\x0B\x0C\x0E-\x1F]/g,'');
  s=s.replace(/\r\n?/g,'\n');
  if((s.match(/\n/g)||[]).length<2&&(s.match(/\\n/g)||[]).length>=2)
    s=s.replace(/\\r\\n|\\n/g,'\n').replace(/\\t/g,' ');
  s=s.replace(/\\u(2018|2019|201C|201D|2013|2014|2022|2026|00A0|003E)/gi,(full,hex)=>String.fromCharCode(parseInt(hex,16)));
  const names={amp:'&',gt:'>',lt:'<',quot:'"',apos:"'",nbsp:' ',bull:'•',mdash:'—',ndash:'–',hellip:'…'};
  const decode=t=>t.replace(/&(?:#(x[0-9a-fA-F]+|\d+)|([a-zA-Z]+));/g,(full,num,name)=>{
    if(name)return Object.prototype.hasOwnProperty.call(names,name.toLowerCase())?names[name.toLowerCase()]:full;
    const point=num[0].toLowerCase()==='x'?parseInt(num.slice(1),16):parseInt(num,10);
    return point>=32&&point<=0x10FFFF&&!(point>=0xD800&&point<=0xDFFF)?String.fromCodePoint(point):full;
  });
  s=decode(decode(s));
  // Strip model quote wrappers only at the beginning of a line, not ordinary comparisons.
  s=s.split('\n').map(line=>line.replace(/^\s*(?:>\s*)+(?=\S)/,'')).join('\n');
  s=s.replace(/^\s*```(?:md|markdown|text)?\s*$/gmi,'');
  return s.replace(/\n{4,}/g,'\n\n\n').trim();
 }
 const sourceIndex=items=>new Map((Array.isArray(items)?items:[]).filter(x=>Number.isInteger(Number(x.Index))).map(x=>[Number(x.Index),x]));
 function explicitIndex(text,lookup){
  const m=String(text).match(/\[\s*Email\s*#(\d+)\s*\]|\[\s*#(\d+)\s*\]|\bEmail\s*#(\d+)\b/i);
  const number=m&&Number(m[1]||m[2]||m[3]);
  return lookup.has(number)?number:null;
 }
 function linkReferences(escaped,lookup){
  return escaped.replace(/\[\s*Email\s*#(\d+)\s*\]|\[\s*#(\d+)\s*\]|\bEmail\s*#(\d+)\b/gi,(whole,a,b,c)=>{
   const n=Number(a||b||c);
   if(!lookup.has(n))return whole;
   return '<button type="button" class="report-reference" data-report-open-index="'+n+'" aria-label="Open verified email '+n+' in Outlook">Email #'+n+' '+icon('external')+'</button>';
  });
 }
 function inline(text,lookup){
  let s=escapeHtml(text);
  // Untrusted generated URLs are not opened automatically.
  s=s.replace(/\[([^\]]+)\]\((?:https?:\/\/|mailto:)[^)]+\)/gi,'$1');
  s=s.replace(/\*\*(.+?)\*\*/g,'<strong>$1</strong>').replace(/__([^_]+)__/g,'<strong>$1</strong>');
  s=s.replace(/`([^`]+)`/g,'<code>$1</code>').replace(/\*(?!\s)([^*]+)\*/g,'<em>$1</em>');
  return linkReferences(s,lookup);
 }
 function sectionTitle(line){
  const markdown=line.match(/^#{1,4}\s+(.+?)\s*$/);
  if(markdown)return markdown[1];
  const numbered=line.match(/^\d+\.\s+(CATEGORIES|GROUPS|MUST REPLY|ALREADY APPEARS REPLIED\s*\/\s*NO ACTION NEEDED|SKIPPED\s*\/\s*CAUTION|QUICK SUMMARY|ACTION ITEMS|KEY FINDINGS)\s*$/i);
  return numbered?numbered[1]:null;
 }
 function deriveSections(raw){
  const lines=normalizeText(raw).split('\n');
  const result=[];let title='Overview',buffer=[];
  for(const line of lines){
   const t=sectionTitle(line.trim());
   if(t){if(buffer.some(x=>x.trim()))result.push({Id:'section-'+result.length,Title:title,Text:buffer.join('\n').trim()});title=t;buffer=[]}
   else buffer.push(line);
  }
  if(buffer.some(x=>x.trim())||!result.length)result.push({Id:'section-'+result.length,Title:title,Text:buffer.join('\n').trim()});
  return result;
 }
 function sectionIdFor(title,sections,used){
  const simplify=t=>String(t||'').toLowerCase().replace(/^\d+\.\s*/,'').replace(/[^a-z0-9]+/g,' ').trim();
  const name=simplify(title),match=(Array.isArray(sections)?sections:[]).find(s=>!used.has(s.Id)&&simplify(s.Title)===name);
  if(!match)return null;
  used.add(match.Id);return String(match.Id);
 }
 function tableRows(lines,start,lookup){
  const headers=lines[start].trim().replace(/^\|/,'').replace(/\|$/,'').split('|').map(t=>t.trim());
  const rows=[];let i=start+2;
  for(;i<lines.length&&lines[i].trim().startsWith('|');i++)rows.push(lines[i].trim().replace(/^\|/,'').replace(/\|$/,'').split('|').map(t=>t.trim()));
  let html='<div class="report-table-wrap"><table class="report-table"><thead><tr>'+headers.map(t=>'<th>'+inline(t,lookup)+'</th>').join('')+'<th>Source</th></tr></thead><tbody>';
  for(const row of rows){
   let n=null;
   for(const cell of row){n=explicitIndex(cell,lookup);if(n)break}
   if(!n&&/^(?:#|index|email(?:\s*(?:id|number|#))?)$/i.test(headers[0]||'')){
      const num=Number((row[0]||'').replace(/^[#\s]+/,''));
      if(lookup.has(num))n=num;
   }
   if(!n){
      const matches=[...lookup.values()].filter(it=>row.some(c=>c.trim().toLowerCase()===String(it.Subject||'').trim().toLowerCase()));
      if(matches.length===1)n=Number(matches[0].Index);
   }
   html+='<tr'+(n?' class="report-linked-row" tabindex="0" data-report-open-index="'+n+'" aria-label="Open email '+n+'"':'')+'>'+
    headers.map((_,j)=>'<td>'+inline(row[j]||'',lookup)+'</td>').join('')+
    '<td>'+(n?'<button class="report-reference" type="button" data-report-open-index="'+n+'">Open #'+n+' '+icon('external')+'</button>':'<span class="report-unlinked">Not linked</span>')+'</td></tr>';
  }
  return {html:html+'</tbody></table></div>',next:i-1};
 }
 function renderMarkdown(raw,items=[],sections=[]){
  if(!String(raw??'').trim())return '<p class="report-placeholder">Analyze inbox to generate a report.</p>';
  const lookup=sourceIndex(items),lines=normalizeText(raw).split('\n');
  let html=[],inList=false,inSection=false,used=new Set();
  const closeList=()=>{if(inList){html.push('</ul>');inList=false}};
  const closeSection=()=>{closeList();if(inSection){html.push('</section>');inSection=false}};
  const sep=line=>/^\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?$/.test(String(line).trim());
  for(let i=0;i<lines.length;i++){
   let line=lines[i].trim();
   if(!line){closeList();continue}
   if(/^```/.test(line))continue;
   const h=sectionTitle(line);
   if(h){
    closeSection();const id=sectionIdFor(h,sections,used);
    html.push('<section class="report-section"><div class="report-section-heading"><h2>'+inline(h,lookup)+'</h2>'+
      (id?'<button class="report-section-action" type="button" data-report-generate-section="'+escapeHtml(id)+'">'+icon('intelligence')+' Generate from section</button>':'')+'</div>');
    inSection=true;continue;
   }
   if(/^[-*_]{3,}$/.test(line)){closeList();html.push('<hr>');continue}
   if(line.startsWith('|')&&i+1<lines.length&&sep(lines[i+1])){
    closeList();const table=tableRows(lines,i,lookup);html.push(table.html);i=table.next;continue;
   }
   const bullet=line.match(/^(?:[-*•]\s+|\d+[.)]\s+)(.*)$/);
   if(bullet){if(!inList){html.push('<ul class="report-list">');inList=true}html.push('<li>'+inline(bullet[1],lookup)+'</li>');continue}
   closeList();
   // Recovered tables from the AI model may use colon key-value lines.
   if(/^\*\*[^*]{2,100}:\*\*/.test(line)){html.push('<p class="report-emphasis">'+inline(line,lookup)+'</p>');continue}
   html.push('<p>'+inline(line,lookup)+'</p>');
  }
  closeSection();
  return html.join('');
 }
 function renderSources(items,trackedKeys,query=''){
  const queryText=String(query||'').trim().toLowerCase(),data=Array.isArray(items)?items:[];
  const list=data.filter(it=>[it.Subject,it.From,it.Section,it.Reason,it.RecommendedAction].some(v=>String(v||'').toLowerCase().includes(queryText)));
  if(!list.length)return '<div class="empty">No verified sources match this search.</div>';
  return list.map(it=>{
   const key=escapeHtml(it.Key||''),subject=escapeHtml(it.Subject||'(No subject)'),idx=Number(it.Index);
   const tracked=trackedKeys?.has(String(it.Key))||it.Tracked;
   const status=it.ManuallyPrioritized?'Manually prioritized':it.RuleSuppressed?'Excluded by rule':tracked?'Tracked action':'Source verified';
   return '<article class="report-source-item" data-report-source="'+idx+'">'+
    '<div class="report-source-meta"><span class="report-source-index">#'+idx+'</span> <span class="report-source-section">'+escapeHtml(it.Section||'Source inbox')+'</span> <span class="report-source-status">'+status+'</span></div>'+
    '<button type="button" class="report-source-title" data-report-open="'+key+'">'+subject+'</button>'+
    '<p class="report-source-detail">'+escapeHtml(it.From||'')+' · '+escapeHtml(it.Reason||'')+'</p>'+
    (it.RuleSuppressed?'<p class="report-source-warning">Rule exclusion: '+escapeHtml(it.RuleSuppressedBy||'Matched a filtering rule')+'. You can explicitly track this message.</p>':'')+
    (it.RecommendedAction?'<p class="report-source-suggestion">Suggested: '+escapeHtml(it.RecommendedAction)+'</p>':'')+
    '<div class="report-source-actions"><button type="button" data-report-open="'+key+'">Open Outlook '+icon('external')+'</button>'+
    '<button type="button" data-report-draft="'+key+'">'+icon('draft')+' Draft reply</button>'+
    (tracked?'<button type="button" data-report-queue="'+key+'">View in queue</button>':
     '<button type="button" data-report-track="'+key+'">'+icon('plus')+' Track action</button>')+'</div></article>';
  }).join('');
 }
 function audit(raw,items,sections){
  const clean=normalizeText(raw),lookup=sourceIndex(items),warnings=[];
  const unknown=[...clean.matchAll(/\[\s*Email\s*#(\d+)\s*\]|\[\s*#(\d+)\s*\]/gi)].map(m=>Number(m[1]||m[2])).filter(n=>!lookup.has(n));
  if(unknown.length)warnings.push('Unverified model email references: '+[...new Set(unknown)].join(', ')+'. These are not clickable.');
  if(/�|Ã.|â€|Â[^\s]/.test(clean))warnings.push('Unresolved encoding artifacts remain; inspect the source output.');
  if(/@@@PACKETRAT_JSON_|```/.test(clean))warnings.push('Unrecognized structured/model formatting remains in the report.');
  if(!(Array.isArray(sections)?sections:[]).length)warnings.push('The report has no reliably parsed sections.');
  return {warnings,verifiedSources:lookup.size,sections:(sections||[]).length,unverifiedRefs:[...new Set(unknown)]};
 }
 function renderStructured(sections,verifiedItems,reportSections=[]){
  if(!Array.isArray(sections)||!sections.length)return '<p class="report-placeholder">No structured report available.</p>';
  const sources=sourceIndex(verifiedItems),seen=new Set();
  return sections.map((section,i)=>{
   const title=escapeHtml(normalizeText(section.Title||section.title||'Untitled section'));
   const id=reportSections[i]?.Id||'section-'+i;
   const heading='<div class="report-section-heading"><h2>'+title+'</h2><button type="button" class="report-section-action" data-report-generate-section="'+escapeHtml(id)+'">'+icon('intelligence')+' Generate from section</button></div>';
   const summary=normalizeText(section.Summary||section.summary||'');
   let html='<section class="report-section" data-report-section="'+escapeHtml(section.Id||section.id||'')+'">'+heading;
   if(summary)html+='<p>'+escapeHtml(summary)+'</p>';
   const entries=Array.isArray(section.Items)?section.Items:Array.isArray(section.items)?section.items:[];
   if(entries.length){
    html+='<ul class="report-list report-structured-list">';
    for(const entry of entries){
     const message=normalizeText(entry.Text||entry.text||'');
     if(!message.trim())continue;
     const index=Number(entry.EmailIndex||entry.email_index||0);
     const eligible=index>0&&sources.has(index);
     const sourceLink=eligible?'<button type="button" class="report-reference" data-report-open-index="'+index+'">Email #'+index+' '+icon('external')+'</button> ':
      index>0?'<span class="report-unlinked">Source #'+index+' not verified</span> ':'';
     html+='<li>'+sourceLink+escapeHtml(message)+'</li>';
     if(eligible)seen.add(index);
    }
    html+='</ul>';
   }else if(!summary)html+='<p class="report-placeholder">No findings in this section.</p>';
   return html+'</section>';
  }).join('');
 }
 root.PacketRatReport={normalizeText,deriveSections,renderMarkdown,renderStructured,renderSources,audit,escapeHtml};
})(typeof globalThis!=='undefined'?globalThis:this);
