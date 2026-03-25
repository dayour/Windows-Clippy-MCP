from pywinauto import Desktop
pid = 28768
windows = [w for w in Desktop(backend='uia').windows() if w.process_id() == pid]
for w in windows:
    print('TOP', repr(w.window_text()), w.rectangle())
    for d in w.descendants()[:250]:
        try:
            print('DESC', repr(d.window_text()), d.friendly_class_name(), d.element_info.control_type, d.rectangle())
        except Exception as e:
            print('DESC_ERR', e)
