import xcffib
_events = {}
_errors = {}
class STR(xcffib.Struct):
    def __init__(self, unpacker):
        if isinstance(unpacker, xcffib.Protobj):
            unpacker = xcffib.MemoryUnpacker(unpacker.pack())
        xcffib.Struct.__init__(self, unpacker)
        base = unpacker.offset
        self.name_len, = unpacker.unpack("B")
        self.name = xcffib.List(unpacker, "c", self.name_len)
        self.bufsize = unpacker.offset - base
    def pack(self):
        packer = xcffib.Packer()
        packer.pack("=B", self.name_len)
        packer.pack_list(self.name, "c")
        return packer.getvalue()
class ListExtensionsReply(xcffib.Reply):
    def __init__(self, unpacker):
        if isinstance(unpacker, xcffib.Protobj):
            unpacker = xcffib.MemoryUnpacker(unpacker.pack())
        xcffib.Reply.__init__(self, unpacker)
        base = unpacker.offset
        self.names_len, = unpacker.unpack("xB2x4x24x")
        self.names = xcffib.List(unpacker, STR, self.names_len)
        self.bufsize = unpacker.offset - base
class ListExtensionsCookie(xcffib.Cookie):
    reply_type = ListExtensionsReply
class request_replyExtension(xcffib.Extension):
    def ListExtensions(self, is_checked=True):
        packer = xcffib.Packer()
        packer.pack("=xx2x")
        return self.send_request(99, packer, ListExtensionsCookie, is_checked=is_checked)
xcffib._add_ext(key, request_replyExtension, _events, _errors)
