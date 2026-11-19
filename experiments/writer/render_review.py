"""Review generated files using a Python browser host, without App code."""
import argparse
import asyncio
import json
from pathlib import Path
import tempfile
from workspace import safe_path


async def review(files, entry, counter=False):
    from playwright.async_api import async_playwright
    with tempfile.TemporaryDirectory(prefix='writer-review-') as directory:
        root=Path(directory)
        for name,content in files.items():
            target=root/safe_path(name);target.parent.mkdir(parents=True,exist_ok=True);target.write_text(content)
        async with async_playwright() as pw:
            browser=await pw.chromium.launch()
            try:
                page=await browser.new_page(viewport={'width':390,'height':844})
                await page.route('http://**/*',lambda route:route.abort())
                await page.route('https://**/*',lambda route:route.abort())
                errors=[];page.on('pageerror',lambda error:errors.append(str(error)))
                await page.goto((root/safe_path(entry)).as_uri(),wait_until='load',timeout=15000)
                before=await page.locator('body').inner_text();changed=False
                if counter:
                    button=page.locator('#increment')
                    if await button.count():
                        await button.click(timeout=5000)
                        changed=await page.locator('body').inner_text()!=before
                return dict(text=await page.locator('body').inner_text(),errors=errors,counterChanged=changed,
                            diagram=bool(await page.locator('svg,canvas').count()))
            finally:await browser.close()


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('directory',type=Path);p.add_argument('--entry',required=True)
    args=p.parse_args();files={str(f.relative_to(args.directory)):f.read_text() for f in args.directory.rglob('*') if f.is_file()}
    print(json.dumps(asyncio.run(review(files,args.entry)),ensure_ascii=False,indent=2))


if __name__=='__main__':main()
