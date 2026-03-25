from pywinauto import Desktop
pid = 47336
wins = [w for w in Desktop(backend='uia').windows() if w.process_id()==pid]
print('WINDOWS', len(wins))
for w in wins:
    print('WIN', repr(w.window_text()), w.rectangle())
    texts = [d.window_text() for d in w.descendants() if d.element_info.control_type == 'Text']
    for t in texts:
        if t.startswith('Clippy tab:') or t.startswith('Tabs:'):
            print('TEXT', t)
    docs = [d.window_text() for d in w.descendants() if d.element_info.control_type == 'Document']
    for doc in docs:
        print('DOC', repr(doc[:400]))
