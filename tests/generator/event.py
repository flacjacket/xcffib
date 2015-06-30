import xcffib
MAJOR_VERSION = 1
MINOR_VERSION = 4
key = xcffib.ExtensionKey("EVENT")
_events = {}
_errors = {}
class ScreenChangeNotifyEvent(xcffib.Event):
    def __init__(self, unpacker):
        if isinstance(unpacker, xcffib.Protobj):
            unpacker = xcffib.MemoryUnpacker(unpacker.pack())
        xcffib.Event.__init__(self, unpacker)
        base = unpacker.offset
        self.rotation, self.timestamp, self.config_timestamp, self.root, self.request_window, self.sizeID, self.subpixel_order, self.width, self.height, self.mwidth, self.mheight = unpacker.unpack("xB2xIIIIHHHHHH")
        self.bufsize = unpacker.offset - base
    def pack(self):
        packer = xcffib.Packer()
        packer.pack("=B", 0, align=1)
        packer.pack("=B2xIIIIHHHHHH", self.rotation, self.timestamp, self.config_timestamp, self.root, self.request_window, self.sizeID, self.subpixel_order, self.width, self.height, self.mwidth, self.mheight)
        buf_len = len(packer.getvalue())
        if buf_len < 32:
            packer.pack("x" * (32 - buf_len))
        return packer.getvalue()
_events[0] = ScreenChangeNotifyEvent
xcffib._add_ext(key, eventExtension, _events, _errors)
