import xcffib
_events = {}
_errors = {}
class requestExtension(xcffib.Extension):
    def CreateWindow(self, depth, wid, parent, x, y, width, height, border_width, _class, visual, value_mask, value_list, is_checked=False):
        packer = xcffib.Packer()
        packer.pack("=xB2xIIhhHHHHI", depth, wid, parent, x, y, width, height, border_width, _class, visual)
        packer.pack("=I", value_mask)
        packer.pack_list(value_list, "I")
        return self.send_request(1, packer, is_checked=is_checked)
xcffib._add_ext(key, requestExtension, _events, _errors)
