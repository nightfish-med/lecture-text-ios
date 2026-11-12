"""從 tools/haiku_prompt/system.txt、schema.json（v0.26.0 起加 card.txt、card_schema.json）產生 Sources/HaikuPromptText.swift（v0.23.2）。

提示詞和 schema 的唯一正本是這個資料夾的兩個檔；Swift 常數不要手抄，每次 commit 前跑一次：
    python tools/haiku_prompt/同步提示詞.py          產生（有變才寫檔）
    python tools/haiku_prompt/同步提示詞.py --check  只檢查，和正本不同就回 1
shape_check（tools/shape_check/haiku_tests.swift）會再讀 system.txt、schema.json 和常數逐字比對。
只用標準函式庫。讀檔時去掉 BOM、\\r\\n 換成 \\n（和 Python 用 read_text 讀到的字一樣）。
"""
import hashlib
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
OUT = REPO / 'Sources' / 'HaikuPromptText.swift'
# v0.26.0：card、cardSchema＝即時模式 1 每批一張卡（擴寫式校正＋整理版＋頁碼）
SOURCES = [('system', HERE / 'system.txt'), ('schema', HERE / 'schema.json'),
           ('card', HERE / 'card.txt'), ('cardSchema', HERE / 'card_schema.json')]


def read(path):
    text = path.read_bytes().decode('utf-8')
    if text.startswith('\ufeff'):
        text = text[1:]
    return text.replace('\r\n', '\n')


def literal(line):
    out = []
    for ch in line:
        if ch == '\\':
            out.append('\\\\')
        elif ch == '"':
            out.append('\\"')
        elif ch == '\t':
            out.append('\\t')
        elif ch == '\r':
            out.append('\\r')
        elif ord(ch) < 0x20 or ord(ch) == 0x7f:
            out.append('\\u{%x}' % ord(ch))
        else:
            out.append(ch)
    return '"' + ''.join(out) + '"'


def constant(name, text):
    # 一行一個字串、用 \n 接回去：換行一個不多一個不少（檔尾有沒有換行也照原樣），不受 Swift 多行字串縮排規則影響。
    rows = ''.join(f'        {literal(line)},\n' for line in text.split('\n'))
    return f'    static let {name} = [\n{rows}    ].joined(separator: "\\n")\n'


def render():
    head = ['// 由 tools/haiku_prompt/同步提示詞.py 產生，不要手改。要改提示詞或 schema：改 tools/haiku_prompt/ 的正本再跑一次。',
            '// 只用 Foundation，shape_check 也編；shape_check 會讀正本逐字比對。']
    for name, path in SOURCES:
        digest = hashlib.sha256(read(path).encode('utf-8')).hexdigest()[:12]
        head.append(f'// {path.name} SHA-256（去 BOM、換行統一成 \\n 之後）前 12 碼：{digest}')
    body = ['import Foundation', '', *head, '', 'enum HaikuPromptText {']
    parts = [constant(name, read(path)) for name, path in SOURCES]
    return '\n'.join(body) + '\n' + '\n'.join(parts) + '}\n'


def main():
    text = render()
    old = OUT.read_text(encoding='utf-8') if OUT.exists() else None
    if '--check' in sys.argv[1:]:
        if old != text:
            print(f'{OUT.name} 和正本不同：跑 python tools/haiku_prompt/同步提示詞.py')
            return 1
        print(f'{OUT.name} 和正本相同')
        return 0
    if old == text:
        print(f'{OUT.name} 沒有變')
        return 0
    OUT.write_bytes(text.encode('utf-8'))
    print(f'已寫 {OUT.name}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
