import time
from pywinauto import Desktop
pid = 28768
for i in range(10):
    w = [x for x in Desktop(backend='uia').windows() if x.process_id()==pid][0]
    texts = [d.window_text() for d in w.descendants() if d.element_info.control_type == 'Text']
    meta = [t for t in texts if t.startswith('Clippy tab:')]
    print(i, meta[0] if meta else 'NO_META')
    time.sleep(2)
