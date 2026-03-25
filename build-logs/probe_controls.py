from pywinauto import Desktop
pid = 28768
w = [x for x in Desktop(backend='uia').windows() if x.process_id()==pid][0]
chat = [d for d in w.descendants() if d.window_text() == 'Clippy Session'][0]
for ctrl in chat.descendants():
    t = ctrl.window_text()
    ct = ctrl.element_info.control_type
    if ct in ('Button','Edit','Document','ComboBox','Text') and (t or ct in ('Edit','ComboBox','Document')):
        print(ct, repr(t), ctrl.rectangle())
