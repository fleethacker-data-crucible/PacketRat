"""Development-only end-to-end smoke checks; target host needs no Python."""
from __future__ import annotations
import contextlib
import http.server
import socketserver
import threading
import base64
import tempfile
from pathlib import Path
from playwright.sync_api import sync_playwright

WEB = Path(__file__).resolve().parents[1] / "Web"

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WEB), **kwargs)
    def log_message(self, *args):
        pass


def run():
    with socketserver.TCPServer(('127.0.0.1', 0), Handler) as server:
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        try:
            with sync_playwright() as playwright:
                browser = playwright.chromium.launch(headless=True,args=['--no-sandbox'])
                page = browser.new_page(viewport={'width': 1450, 'height': 960},device_scale_factor=1)
                errors=[]
                page.on('pageerror', lambda err:errors.append(str(err)))
                # Browser navigation is prohibited in some test sandboxes; inline
                # exactly the same shipped HTML/CSS/JS through Playwright.
                html = (WEB/'index.html').read_text().replace('<html lang="en">','<html lang="en" data-demo="1">')
                html = html.replace('<link rel="stylesheet" href="style.css">','')
                html = html.replace('<script defer src="app.js"></script>','')
                for name in ('mailhawk-icon.png','mailhawk-logo.png'):
                    encoded = base64.b64encode((WEB/name).read_bytes()).decode()
                    html = html.replace('src="'+name+'"','src="data:image/png;base64,'+encoded+'"')
                page.set_content(html)
                page.add_style_tag(content=(WEB/'style.css').read_text())
                page.evaluate("""() => {
                    const memory = {};
                    Object.defineProperty(window, 'sessionStorage', {configurable:true, value:{getItem:k=>memory[k]||null,setItem:(k,v)=>memory[k]=v}});
                    Object.defineProperty(window, 'localStorage', {configurable:true, value:{getItem:()=>null,setItem:()=>{}}});
                }""")
                page.add_script_tag(content=(WEB/'app.js').read_text())
                page.wait_for_selector('#mOpen:text-is("3")')
                assert page.locator('#mHigh').inner_text()=='2'
                assert page.locator('#demoBanner').is_visible()
                assert page.locator('.brand img').evaluate('(img) => img.naturalWidth') > 0
                assert page.locator('.hero-art img').evaluate('(img) => img.naturalWidth') > 0
                page.screenshot(path=str(Path(tempfile.gettempdir())/'mailhawk-overview-smoke.png'),full_page=True)
                page.locator('#priorityList .item-title').first.click()
                page.wait_for_function("document.getElementById('notice').textContent.includes('Demo mode')")
                page.locator('[data-metric="high"]').click()
                assert page.locator('#triage').is_visible()
                assert page.locator('#queue .item').count()==2
                page.locator('[data-filter="all"]').click()
                page.locator('.sidebar [data-view="triage"]').click()
                assert page.locator('#triage').is_visible()
                assert page.locator('#queue .item').count()==4
                page.locator('#queue [data-priority-key]').first.select_option('Low')
                page.wait_for_function("document.getElementById('notice').textContent.includes('Priority updated')")
                page.locator('#queueSearch').fill('milestone')
                assert page.locator('#queue .item').count()==1
                page.locator('#queueSearch').fill('')
                page.screenshot(path=str(Path(tempfile.gettempdir())/'mailhawk-queue-smoke.png'),full_page=True)
                page.once('dialog', lambda dialog: dialog.accept('Sample false positive'))
                page.locator('#queue [data-act="dismiss"]').first.click()
                page.wait_for_function("document.getElementById('mDismiss').textContent === '1'")
                page.get_by_role('button',name='Dismissal memory').click()
                assert page.locator('#dismissList .item').count()==1
                page.get_by_role('button',name='Restore').click()
                page.wait_for_function("document.getElementById('mDismiss').textContent === '0'")
                page.locator('.sidebar [data-view="triage"]').click()
                page.locator('#queue [data-act="draft"]').first.click()
                assert page.locator('#draftDialog').is_visible()
                page.locator('#generateDraft').click()
                page.wait_for_function("document.getElementById('draftBody').value.length > 30")
                assert page.locator('#draftOptions .draft-option').count()==2
                page.locator('[data-draft-option="B"]').click()
                assert 'appreciate' in page.locator('#draftBody').input_value()
                page.locator('#draftBody').fill('Customized option B.')
                page.locator('[data-draft-option="A"]').click()
                page.locator('[data-draft-option="B"]').click()
                assert page.locator('#draftBody').input_value()=='Customized option B.'
                page.locator('#closeDialog').click()
                page.get_by_role('button',name='Configuration').click()
                assert page.locator('#settings').is_visible()
                assert page.locator('#rulesList .rule-row').count() == 5
                page.locator('#addRule').click()
                assert page.locator('#rulesList .rule-row').count() == 6
                page.locator('#saveRules').click()
                page.wait_for_function("document.getElementById('rulesStatus').textContent.includes('Saved')")
                assert page.locator('#rulesList .rule-row').count() == 6
                page.locator('[data-view="report"]').click()
                assert page.locator('#reportText h2').count() >= 3
                assert page.locator('#credentialSource').is_visible()
                assert not page.locator('#manualTokenFields').is_visible()
                page.locator('#credentialSource').select_option('Manual')
                assert page.locator('#manualTokenFields').is_visible()
                page.locator('#credentialToken').fill('TEST-ONLY-DO-NOT-USE')
                page.locator('#applyCredentials').click()
                assert page.locator('#credentialToken').input_value() == ''
                assert 'Demo mode' in page.locator('#notice').inner_text()
                assert not errors, f'Browser errors: {errors}'
                browser.close()
        finally:
            server.shutdown()

if __name__=='__main__':
    run()
    print('Playwright browser demo smoke checks passed')
