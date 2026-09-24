type WireValue = { kind: "number"; value: bigint } | { kind: "bytes"; value: Uint8Array };

export class WireMessage {
  private readonly fields = new Map<number, WireValue[]>();

  static decode(bytes: Uint8Array): WireMessage | null {
    const result = new WireMessage();
    let offset = 0;
    const readVarint = (): bigint | null => {
      let value = 0n;
      for (let shift = 0n; shift < 70n; shift += 7n) {
        if (offset >= bytes.length) return null;
        const byte = bytes[offset++];
        if (byte === undefined) return null;
        value |= BigInt(byte & 0x7f) << shift;
        if ((byte & 0x80) === 0) return value;
      }
      return null;
    };
    while (offset < bytes.length) {
      const tag = readVarint();
      if (tag === null || tag < 8n || tag > 0xffffffffn) return null;
      const field = Number(tag >> 3n);
      const wireType = Number(tag & 7n);
      let item: WireValue;
      if (wireType === 0) {
        const value = readVarint();
        if (value === null) return null;
        item = { kind: "number", value };
      } else if (wireType === 2) {
        const length = readVarint();
        if (length === null || length > BigInt(bytes.length - offset)) return null;
        const size = Number(length);
        item = { kind: "bytes", value: bytes.subarray(offset, offset + size) };
        offset += size;
      } else if (wireType === 1 || wireType === 5) {
        const size = wireType === 1 ? 8 : 4;
        if (offset + size > bytes.length) return null;
        offset += size;
        continue;
      } else return null;
      const list = result.fields.get(field) ?? [];
      list.push(item);
      result.fields.set(field, list);
    }
    return result;
  }

  bytes(field: number): Uint8Array | null {
    const item = this.fields.get(field)?.find((value) => value.kind === "bytes");
    return item?.kind === "bytes" ? item.value : null;
  }

  number(field: number): bigint | null {
    const item = this.fields.get(field)?.find((value) => value.kind === "number");
    return item?.kind === "number" ? item.value : null;
  }

  text(field: number): string | null {
    const bytes = this.bytes(field);
    if (!bytes) return null;
    const text = new TextDecoder("utf-8", { fatal: true });
    try {
      return text.decode(bytes);
    } catch {
      return null;
    }
  }

  child(field: number): WireMessage | null {
    const bytes = this.bytes(field);
    return bytes ? WireMessage.decode(bytes) : null;
  }

  children(field: number): WireMessage[] {
    return (this.fields.get(field) ?? []).flatMap((value) => {
      if (value.kind !== "bytes") return [];
      const decoded = WireMessage.decode(value.value);
      return decoded ? [decoded] : [];
    });
  }

  timestamp(field: number): string | null {
    const value = this.child(field);
    const seconds = value?.number(1);
    if (seconds === null || seconds === undefined) return null;
    const millis = Number(seconds) * 1_000 + Number(value?.number(2) ?? 0n) / 1_000_000;
    const date = new Date(millis);
    return Number.isNaN(date.valueOf()) ? null : date.toISOString();
  }
}
