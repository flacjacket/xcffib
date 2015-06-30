import xcffib
_events = {}
_errors = {}
class KeymapNotifyEvent(xcffib.Event):
    def __init__(self, unpacker):
        if isinstance(unpacker, xcffib.Protobj):
            unpacker = xcffib.MemoryUnpacker(unpacker.pack())
        xcffib.Event.__init__(self, unpacker)
        base = unpacker.offset
        unpacker.unpack("x")
        self.keys = xcffib.List(unpacker, "B", 31)
        self.bufsize = unpacker.offset - base
    def pack(self):
        packer = xcffib.Packer()
        packer.pack("=B", 11, align=1)
        packer.pack_list(self.keys, "B")
        buf_len = len(packer.getvalue())
        if buf_len < 32:
            packer.pack("x" * (32 - buf_len))
        return packer.getvalue()
_events[11] = KeymapNotifyEvent
xcffib._add_ext(key, no_sequenceExtension, _events, _errors)
