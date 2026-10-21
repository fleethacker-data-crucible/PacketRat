"""Development-only end-to-end smoke checks; target host needs no Python."""
from __future__ import annotations
import contextlib
import http.server
import socketserver
import threading
import base64
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
                browser = playwright.chromium.launch(executable_path='/usr/bin/chromium',headless=True,args=['--no-sandbox'])
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
                page.screenshot(path='/mnt/data/mailhawk_v2/overview-preview.png',full_page=True)
                page.locator('.sidebar [data-view="triage"]').click()
                assert page.locator('#triage').is_visible()
                assert page.locator('#queue .item').count()==4
                page.locator('#queueSearch').fill('milestone')
                assert page.locator('#queue .item').count()==1
                page.locator('#queueSearch').fill('')
                page.screenshot(path='/mnt/data/mailhawk_v2/queue-preview.png',full_page=True)
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
                page.locator('#closeDialog').click()
                page.get_by_role('button',name='Configuration').click()
                assert page.locator('#settings').is_visible()
                assert not errors, f'Browser errors: {errors}'
                browser.close()
        finally:
            server.shutdown()

if __name__=='__main__':
    run()
    print('Playwright browser demo smoke checks passed')
