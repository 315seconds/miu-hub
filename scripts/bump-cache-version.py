#!/usr/bin/env python3
"""
캐시 무효화 스크립트.
모든 HTML 파일의 로컬 .js/.css 참조에 ?v=<version> 자동 추가/갱신.
배포 전 1번 실행.

사용:
  ./scripts/bump-cache-version.py             # UTC 타임스탬프로 자동 세팅 (권장)
  ./scripts/bump-cache-version.py 20260921    # 수동 지정
"""
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

# 로컬 .js/.css 만 대상 (외부 CDN은 제외)
PATTERN = re.compile(
    r'((?:src|href)=")'                       # src=" 또는 href="
    r'((?!https?://|//)'                       # 외부 URL 제외 (프로토콜 상대 URL 포함)
    r'[^"?]+\.(?:js|css))'                     # 로컬 경로 + .js/.css
    r'(\?v=[^"]*)?'                            # 기존 ?v=... 있으면 매치
    r'(")'                                     # 닫는 "
)

ROOT = Path(__file__).parent.parent

EXCLUDE_HTML = {
    'index-legacy.html',
    'move/index-iframe-backup.html',
    'report/index-iframe-backup.html',
    'move/compare-barcodes.html',   # 일회성 유틸
}

def is_excluded(html: Path) -> bool:
    rel = str(html.relative_to(ROOT))
    if rel in EXCLUDE_HTML:
        return True
    if rel.startswith(('scripts/', '.git/', 'node_modules/', 'supabase/')):
        return True
    if rel.endswith('-backup.html') or rel.endswith('-legacy.html'):
        return True
    return False

def bump(html: Path, version: str) -> int:
    text = html.read_text(encoding='utf-8')
    def repl(m):
        attr, path, _existing, close = m.group(1), m.group(2), m.group(3), m.group(4)
        return f'{attr}{path}?v={version}{close}'
    new_text, count = PATTERN.subn(repl, text)
    if count > 0:
        html.write_text(new_text, encoding='utf-8')
    return count

def main():
    version = sys.argv[1] if len(sys.argv) > 1 else datetime.now(timezone.utc).strftime('%Y%m%d%H%M')
    html_files = sorted(f for f in ROOT.rglob('*.html') if not is_excluded(f))
    total_refs = 0
    changed_files = 0
    for f in html_files:
        n = bump(f, version)
        if n > 0:
            changed_files += 1
            total_refs += n
    print(f"버전: v={version}")
    print(f"수정된 HTML: {changed_files}/{len(html_files)}개")
    print(f"수정된 로컬 .js/.css 참조: {total_refs}개")

if __name__ == '__main__':
    main()
