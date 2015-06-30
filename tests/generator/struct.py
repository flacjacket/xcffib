import xcffib
_events = {}
_errors = {}
class AxisInfo(xcffib.Struct):
    def __init__(self, unpacker):
        if isinstance(unpacker, xcffib.Protobj):
            unpacker = xcffib.MemoryUnpacker(unpacker.pack())
        xcffib.Struct.__init__(self, unpacker)
        base = unpacker.offset
        self.resolution, self.minimum, self.maximum = unpacker.unpack("Iii")
        self.bufsize = unpacker.offset - base
    def pack(self):
        packer = xcffib.Packer()
        packer.pack("=Iii", self.resolution, self.minimum, self.maximum)
        return packer.getvalue()
    fixed_size = 12
class ValuatorInfo(xcffib.Struct):
    def __init__(self, unpacker):
        if isinstance(unpacker, xcffib.Protobj):
            unpacker = xcffib.MemoryUnpacker(unpacker.pack())
        xcffib.Struct.__init__(self, unpacker)
        base = unpacker.offset
        self.class_id, self.len, self.axes_len, self.mode, self.motion_size = unpacker.unpack("BBBBI")
        self.axes = xcffib.List(unpacker, AxisInfo, self.axes_len)
        self.bufsize = unpacker.offset - base
    def pack(self):
        packer = xcffib.Packer()
        packer.pack("=BBBBI", self.class_id, self.len, self.axes_len, self.mode, self.motion_size)
        packer.pack_list(self.axes, AxisInfo)
        return packer.getvalue()
xcffib._add_ext(key, structExtension, _events, _errors)
