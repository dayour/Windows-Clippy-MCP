import sys
pid = 28768
from pywinauto import Desktop
windows = [w for w in Desktop(backend='uia').windows() if w.process_id() == pid]
print('WINDOW_COUNT', len(windows))
for w in windows:
    print('WINDOW', repr(w.window_text()), w.friendly_class_name(), w.rectangle())
    for child in w.children()[:80]:
        try:
            print('  CHILD', repr(child.window_text()), child.friendly_class_name(), child.element_info.control_type)
        except Exception as e:
            print('  CHILD_ERR', e)
