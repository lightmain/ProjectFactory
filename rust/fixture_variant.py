"""Bounded test-side inspection of the fixture's whitelisted Godot Variants."""
import struct


class Reader:
    def __init__(self, data):
        self.data = data
        self.offset = 0
        self.typed_containers = []

    def take(self, length):
        if length < 0 or self.offset + length > len(self.data):
            raise ValueError("truncated fixture Variant")
        result = self.data[self.offset:self.offset + length]
        self.offset += length
        return result

    def unpack(self, format):
        return struct.unpack("<" + format, self.take(struct.calcsize("<" + format)))

    def count(self):
        count, = self.unpack("I")
        if count > 2_000_000:
            raise ValueError("fixture collection exceeds inspection bound")
        return count

    def typed(self, kind):
        if kind == 0:
            return None
        if kind != 1:
            raise ValueError("object/script fixture types are forbidden")
        builtin, = self.unpack("I")
        if builtin > 38 or builtin == 24:
            raise ValueError("invalid fixture builtin type")
        return builtin

    def value(self, depth=0):
        if depth >= 64:
            raise ValueError("fixture nesting exceeds inspection bound")
        header, = self.unpack("I")
        kind = header & 0xFFFF
        wide = bool(header & 0x10000)
        if kind == 0:
            return None
        if kind == 1:
            value, = self.unpack("I")
            if value > 1:
                raise ValueError("invalid boolean")
            return bool(value)
        if kind == 2:
            return self.unpack("q" if wide else "i")[0]
        if kind == 3:
            return self.unpack("d" if wide else "f")[0]
        if kind == 4:
            size = self.count()
            value = self.take(size).decode("utf-8")
            self.take((-size) % 4)
            return value
        if kind == 9:
            return ("vector3", *self.unpack("ddd" if wide else "fff"))
        if kind == 10:
            return ("vector3i", *self.unpack("iii"))
        if kind == 27:
            key_type = self.typed((header >> 16) & 3)
            value_type = self.typed((header >> 18) & 3)
            self.typed_containers.append(("dictionary", key_type, value_type))
            result = {}
            for _ in range(self.count()):
                key = self.value(depth + 1)
                value = self.value(depth + 1)
                if key in result:
                    raise ValueError("duplicate fixture key")
                result[key] = value
            return result
        if kind == 28:
            element_type = self.typed((header >> 16) & 3)
            self.typed_containers.append(("array", element_type))
            return [self.value(depth + 1) for _ in range(self.count())]
        if kind == 29:
            size = self.count()
            result = self.take(size)
            self.take((-size) % 4)
            return result
        packed = {30: ("int32s", "i"), 31: ("int64s", "q"),
                  32: ("float32s", "f"), 33: ("float64s", "d")}
        if kind in packed:
            name, format = packed[kind]
            return (name, self.unpack(format * self.count()))
        if kind == 36:
            return ("vector3s", self.unpack(("ddd" if wide else "fff") * self.count()))
        raise ValueError(f"unsupported fixture Variant: {header:#x}")


def decode(data):
    reader = Reader(data)
    value = reader.value()
    if reader.offset != len(data):
        raise ValueError("trailing fixture Variant bytes")
    return value


def native_checkpoint_counts(data):
    """Inspect the pinned RustConveyor v1/v2 checkpoint, never engine memory."""
    reader = Reader(data)
    if reader.take(8) not in (b"RCNV\x01\0\0\0", b"RCNV\x02\0\0\0"):
        raise ValueError("unknown native fixture checkpoint")
    weighted = data[4] == 2
    reader.take(24)  # speed, dt, minimum (binary64)
    frame, initial, produced, consumed, transferred, removed, _, _, _, objects = reader.unpack("10Q")
    if objects > 2_000_000:
        raise ValueError("native fixture object count exceeds inspection bound")
    queue_items = 0
    for _ in range(objects):
        *_, levels = reader.unpack("9Q")
        reader.take(levels * 8)
        reader.take(6 * 24)  # three input and three output port records
        count, = reader.unpack("Q")
        reader.take(count * 24)  # item identity and compensated distance
        queue_items += count
    if weighted:
        routes, = reader.unpack("Q")
        reader.take(routes * 24)
        paths, = reader.unpack("Q")
        if paths > objects:
            raise ValueError("native fixture path count exceeds object count")
        for _ in range(paths):
            _, pieces = reader.unpack("2Q")
            reader.take(pieces * 16)
    if reader.offset != len(data):
        raise ValueError("trailing native fixture bytes")
    if initial + produced - consumed - removed != queue_items:
        raise ValueError("native fixture conservation mismatch")
    return {"frame": frame, "items": queue_items,
            "transactions": produced + consumed + transferred}
