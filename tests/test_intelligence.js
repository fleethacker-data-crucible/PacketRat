/* Pure report formatting and verified reference contract. Development Node only. */
'use strict';
const fs=require('fs'),path=require('path'),assert=require('assert'),vm=require('vm');
const root=path.join(__dirname,'..');
const report=fs.readFileSync(path.join(root,'Web/report-experience.js'),'utf8');
const html=fs.readFileSync(path.join(root,'Web/index.html'),'utf8');
const app=fs.readFileSync(path.join(root,'Web/app.js'),'utf8');
new vm.Script(report);
new vm.Script(app);
const context={};
vm.createContext(context);
vm.runInContext(report,context);
const ui=context.MailHawkReport;
const samples=[
 {Index:1,Key:'verified-1',Subject:'Access approval',From:'Reviewer',Section:'Must Reply',Reason:'Direct task',Urgency:'High',Tracked:true},
 {Index:2,Key:'verified-2',Subject:'Routine digest',From:'Digest',Section:'No Action Needed',Reason:'FYI',Urgency:'Low',Tracked:false}
];
const messy='## 1. Must Reply\n> [Email #1] Donâ€™t forget the â€“ deadline.\n\n| Email # | Subject | Recommendation |\n| --- | --- | --- |\n| 1 | Access approval | <script>alert(1)</script> |\n| 999 | Unknown sender | Ignore |\n\n## 2. No Action Needed\n- [Email #2] Â Routine digest\n- [Email #999] fabricated source';
const clean=ui.normalizeText(messy);
assert(clean.includes('Don’t'),'Repair known UTF-8/Windows-1252 artifacts');
assert(clean.includes('–'),'Repair a mojibake en dash');
assert(ui.normalizeText('Double encoded Ã¢â‚¬â„¢ quote').includes('’'),'Double-encoded punctuation repaired');
assert(!clean.includes('â€™'),'No source mojibake');
const sections=ui.deriveSections(messy);
const rendered=ui.renderMarkdown(messy,samples,sections);
assert(rendered.includes('<h2>1. Must Reply</h2>'),'Markdown heading');
assert(rendered.includes('data-report-open-index="1"'),'Verified clickthrough');
assert(!rendered.includes('data-report-open-index="999"'),'Fabricated link never made actionable');
assert(rendered.includes('&lt;script&gt;alert(1)&lt;/script&gt;'),'HTML escaped');
assert(!rendered.includes('<script>'),'No HTML execution');
assert(rendered.includes('<table'),'Markdown table');
assert(rendered.includes('<button'),'Interactive report links');
assert(rendered.includes('report-section-action'),'Section generation actions');
const out=ui.renderSources(samples,new Set(['verified-1']),'');
assert(out.includes('data-report-draft="verified-1"'),'Draft action for verified source');
assert(out.includes('data-report-track="verified-2"'),'Track action only for untracked source');
assert(!out.includes('data-report-track="fake"'),'Cannot invent identities');
const audit=ui.audit(messy,samples,sections);
assert(audit.unverifiedRefs.includes(999),'Highlight fabricated references');
const list=ui.renderMarkdown('1. CATEGORIES\n• High priority\n\n2. MUST REPLY\n1. Call owner\n2. Confirm deadline',samples,ui.deriveSections('1. CATEGORIES\n• High priority\n\n2. MUST REPLY\n1. Call owner\n2. Confirm deadline'));
assert(list.includes('<ul'),'Bullets and numbered actions');
for(const id of ['reportQuality','reportScope','reportMode','generateReport','reportGenerated','reportSourceSearch','reportSources','reportText'])
 assert(html.includes('id="'+id+'"'),'Missing report control '+id);
assert(html.includes('src="report-experience.js"'),'Renderer must be loaded');
console.log('Verified interactive report, sanitization and security contract passed');
