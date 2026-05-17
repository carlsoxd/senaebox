#!/usr/bin/env python3
"""
SenaeBox — Inspector de flujos AMF

Lee un archivo .mitm capturado por mitmproxy (con SENAE_CAPTURE=1) y
muestra el tráfico hacia los endpoints messagebroker de Ecuapass.
Decodifica envelopes AMF0 con cuerpos AMF3 (BlazeDS wire format).

Uso:
    python3 proxy/amf_inspect.py ~/.local/share/senaebox/logs/flows_*.mitm

Requiere mitmproxy instalado (mismo entorno que mitmdump):
    pip install mitmproxy
"""

import struct
import sys
from typing import Any


# =============================================================================
# AMF3 decoder
# =============================================================================

class AMF3Decoder:
    """
    Decodificador AMF3 con tablas de referencia de strings, objetos y clases.
    Una instancia por response body (las tablas no se comparten entre mensajes).
    """

    def __init__(self, buf: bytes):
        self.buf = buf
        self.strings: list[str] = []
        self.objects: list[Any] = []
        self.classes: list[tuple] = []

    # ------------------------------------------------------------------
    # Primitivas de bajo nivel
    # ------------------------------------------------------------------

    def _u29(self, off: int) -> tuple[int, int]:
        buf = self.buf
        result = 0
        for i in range(4):
            if off >= len(buf):
                raise ValueError(f"buffer underrun leyendo U29 en offset {off}")
            b = buf[off]; off += 1
            if i < 3:
                result = (result << 7) | (b & 0x7F)
                if not (b & 0x80):
                    return result, off
            else:
                result = (result << 8) | b
                return result, off
        return result, off

    def _string(self, off: int) -> tuple[str, int]:
        ref_or_len, off = self._u29(off)
        if ref_or_len & 1 == 0:               # referencia
            idx = ref_or_len >> 1
            return (self.strings[idx] if idx < len(self.strings) else f"<strref:{idx}>"), off
        length = ref_or_len >> 1
        s = self.buf[off : off + length].decode("utf-8", errors="replace")
        if s:                                  # cadena vacía no va a la tabla
            self.strings.append(s)
        return s, off + length

    # ------------------------------------------------------------------
    # Decodificación de valores
    # ------------------------------------------------------------------

    def value(self, off: int) -> tuple[str, int]:
        """Decodifica un valor AMF3 y devuelve (repr, siguiente_offset)."""
        buf = self.buf
        if off >= len(buf):
            return "<eof>", off
        marker = buf[off]; off += 1

        if marker == 0x00: return "undefined", off
        if marker == 0x01: return "null", off
        if marker == 0x02: return "false", off
        if marker == 0x03: return "true", off

        if marker == 0x04:                     # Integer U29
            val, off = self._u29(off)
            if val >= 0x10000000:
                val -= 0x20000000              # signed 29-bit
            return str(val), off

        if marker == 0x05:                     # Double IEEE 754
            if off + 8 > len(buf): return "<double:eof>", len(buf)
            v = struct.unpack_from(">d", buf, off)[0]
            return str(v), off + 8

        if marker == 0x06:                     # String
            s, off = self._string(off)
            return repr(s), off

        if marker == 0x07:                     # XMLDocument
            return self._long_str(off, "XMLDoc")

        if marker == 0x08:                     # Date
            ref_or_zero, off = self._u29(off)
            if ref_or_zero & 1 == 0:
                return f"<date:ref={ref_or_zero>>1}>", off
            if off + 8 > len(buf): return "<date:eof>", len(buf)
            ms = struct.unpack_from(">d", buf, off)[0]
            self.objects.append(f"Date({ms})")
            return f"Date({ms})", off + 8

        if marker == 0x09: return self._array(off)
        if marker == 0x0A: return self._object(off)

        if marker == 0x0B:                     # XML
            return self._long_str(off, "XML")

        if marker == 0x0C:                     # ByteArray
            ref_or_len, off = self._u29(off)
            if ref_or_len & 1 == 0:
                return f"<ba:ref={ref_or_len>>1}>", off
            n = ref_or_len >> 1
            preview = buf[off:off+16].hex()
            return f"ByteArray({n}B:{preview}{'…' if n>16 else ''})", off + n

        if marker in (0x0D, 0x0E):             # Vector<int>, Vector<uint>
            ref_or_count, off = self._u29(off)
            if ref_or_count & 1 == 0: return f"<vec:ref={ref_or_count>>1}>", off
            count = ref_or_count >> 1
            off += 1                           # fixed flag byte
            return f"Vector({count})", off + count * 4

        if marker == 0x0F:                     # Vector<double>
            ref_or_count, off = self._u29(off)
            if ref_or_count & 1 == 0: return f"<vecd:ref={ref_or_count>>1}>", off
            count = ref_or_count >> 1
            off += 1
            return f"VectorDouble({count})", off + count * 8

        if marker == 0x10:                     # Vector<object>
            ref_or_count, off = self._u29(off)
            if ref_or_count & 1 == 0: return f"<veco:ref={ref_or_count>>1}>", off
            count = ref_or_count >> 1
            off += 1
            type_name, off = self._string(off)
            items = []
            for _ in range(min(count, 8)):
                v, off = self.value(off)
                items.append(v)
            return f"Vector<{type_name}>({items})", off

        return f"<AMF3:0x{marker:02x}>", off  # marcador desconocido

    # ------------------------------------------------------------------
    # Tipos compuestos
    # ------------------------------------------------------------------

    def _long_str(self, off: int, label: str) -> tuple[str, int]:
        ref_or_len, off = self._u29(off)
        if ref_or_len & 1 == 0:
            return f"<{label}:ref={ref_or_len>>1}>", off
        n = ref_or_len >> 1
        s = self.buf[off : off + n].decode("utf-8", errors="replace")
        self.objects.append(s)
        return f"{label}({s[:80]}{'…' if len(s)>80 else ''})", off + n

    def _array(self, off: int) -> tuple[str, int]:
        ref_or_count, off = self._u29(off)
        if ref_or_count & 1 == 0:
            return f"<arr:ref={ref_or_count>>1}>", off
        count = ref_or_count >> 1
        obj_idx = len(self.objects)
        self.objects.append(None)

        assoc = {}
        while off < len(self.buf):             # parte asociativa (clave-valor)
            key, off = self._string(off)
            if key == "": break
            val, off = self.value(off)
            assoc[key] = val

        dense = []
        for _ in range(min(count, 20)):        # parte densa
            v, off = self.value(off)
            dense.append(v)

        result = f"Array(assoc={assoc}, dense={dense})"
        self.objects[obj_idx] = result
        return result, off

    def _object(self, off: int) -> tuple[str, int]:
        ref_or_traits, off = self._u29(off)

        if ref_or_traits & 1 == 0:            # referencia a objeto
            idx = ref_or_traits >> 1
            obj = self.objects[idx] if idx < len(self.objects) else f"<objref:{idx}>"
            return str(obj), off

        traits_encoded = ref_or_traits >> 1

        if traits_encoded & 1 == 0:           # referencia a clase
            idx = traits_encoded >> 1
            if idx < len(self.classes):
                class_alias, sealed_props, dynamic, externalizable = self.classes[idx]
            else:
                return f"<traitsref:{idx}>", off
        else:                                  # definición de clase nueva
            externalizable = bool(traits_encoded & 0x02)
            dynamic        = bool(traits_encoded & 0x04)
            prop_count     = traits_encoded >> 3
            class_alias, off = self._string(off)
            sealed_props = []
            for _ in range(prop_count):
                pname, off = self._string(off)
                sealed_props.append(pname)
            self.classes.append((class_alias, sealed_props, dynamic, externalizable))

        obj_idx = len(self.objects)
        self.objects.append(None)

        if externalizable:
            if class_alias in ("DSK", "DSA", "DSC", "DSE"):
                result, off = self._read_ext_message(off, class_alias)
            else:
                remaining = self.buf[off:]
                found = _scan_amf3_strings(remaining)
                result = f"<{class_alias or 'Ext'}> cadenas: {found[:8]}"
                off = len(self.buf)
            self.objects[obj_idx] = result
            return result, off

        fields = {}
        for prop in sealed_props:
            v, off = self.value(off)
            fields[prop] = v
        if dynamic:
            while off < len(self.buf):
                key, off = self._string(off)
                if key == "": break
                v, off = self.value(off)
                fields[key] = v

        label = class_alias or "Object"
        fields_str = ", ".join(f"{k}:{v}" for k, v in list(fields.items())[:10])
        if len(fields) > 10:
            fields_str += ", …"
        result = f"<{label}>{{{fields_str}}}"
        self.objects[obj_idx] = result
        return result, off

    # ------------------------------------------------------------------
    # readExternal() para clases BlazeDS conocidas
    # ------------------------------------------------------------------

    def _read_flags(self, off: int) -> tuple[list[int], int]:
        """Lee bytes de flags BlazeDS (continúa mientras bit 7 esté a 1)."""
        flags = []
        for _ in range(8):                     # máximo 8 grupos de flags
            if off >= len(self.buf):
                break
            b = self.buf[off]; off += 1
            flags.append(b)
            if not (b & 0x80):
                break
        return flags, off

    def _skip_ba_uuid(self, off: int) -> int:
        """Salta un ByteArray de 16 bytes (UUID en formato BlazeDS)."""
        ref_or_len, off = self._u29(off)
        if ref_or_len & 1:
            off += ref_or_len >> 1
        return off

    def _read_ext_message(self, off: int, alias: str) -> tuple[str, int]:
        """
        Implementa readExternal() para la familia AbstractMessage de BlazeDS.

        Jerarquía y orden de serialización (de hijo a padre):
          DSE (ErrorMessage) → flags + faultCode/String/Detail/rootCause
          DSK (AcknowledgeMessage) → flags + correlationId/Bytes
          DSA (AsyncMessage) → flags + correlationId/Bytes
          DSC (CommandMessage) → flags + operation + correlationId/Bytes
          AbstractMessage (base) → flags + body/clientId/dest/headers/
                                   messageId/timestamp/ttl + clientIdBytes/messageIdBytes
        """
        import uuid
        fields = {}

        try:
            # --- ErrorMessage (DSE) fields ---
            if alias == "DSE":
                flags, off = self._read_flags(off)
                f1 = flags[0] if flags else 0
                f2 = flags[1] if len(flags) > 1 else 0
                if f1 & 0x01:
                    v, off = self.value(off); fields["extendedData"] = v
                if f1 & 0x02:
                    v, off = self.value(off); fields["faultCode"] = v
                if f1 & 0x04:
                    v, off = self.value(off); fields["faultDetail"] = v
                if f1 & 0x08:
                    v, off = self.value(off); fields["faultString"] = v
                if f1 & 0x10:
                    v, off = self.value(off); fields["rootCause"] = v

            # --- AcknowledgeMessage (DSK) / CommandMessage (DSC) fields ---
            if alias in ("DSK", "DSC"):
                flags, off = self._read_flags(off)
                f1 = flags[0] if flags else 0
                if f1 & 0x01:
                    v, off = self.value(off); fields["correlationId"] = v
                if f1 & 0x02:
                    off = self._skip_ba_uuid(off)  # correlationIdBytes
                if alias == "DSC" and f1 & 0x04:
                    v, off = self.value(off); fields["operation"] = v

            # --- AsyncMessage (DSA) fields ---
            if alias == "DSA":
                flags, off = self._read_flags(off)
                f1 = flags[0] if flags else 0
                if f1 & 0x01:
                    v, off = self.value(off); fields["correlationId"] = v
                if f1 & 0x02:
                    off = self._skip_ba_uuid(off)

            # --- AbstractMessage (base) fields ---
            flags, off = self._read_flags(off)
            f1 = flags[0] if flags else 0
            f2 = flags[1] if len(flags) > 1 else 0

            if f1 & 0x01:
                v, off = self.value(off); fields["body"] = v
            if f1 & 0x02:
                v, off = self.value(off); fields["clientId"] = v
            if f1 & 0x04:
                v, off = self.value(off); fields["destination"] = v
            if f1 & 0x08:
                v, off = self.value(off); fields["headers"] = v
            if f1 & 0x10:
                v, off = self.value(off); fields["messageId"] = v
            if f1 & 0x20:
                v, off = self.value(off); fields["timestamp"] = v
            if f1 & 0x40:
                v, off = self.value(off); fields["timeToLive"] = v

            # clientIdBytes: ByteArray(16) → UUID
            if f2 & 0x01:
                ref_or_len, off = self._u29(off)
                if ref_or_len & 1:
                    n = ref_or_len >> 1
                    data = self.buf[off:off+n]
                    if n == 16:
                        fields["clientId"] = repr(str(uuid.UUID(bytes=data)))
                    off += n

            # messageIdBytes: ByteArray(16) → UUID
            if f2 & 0x02:
                ref_or_len, off = self._u29(off)
                if ref_or_len & 1:
                    n = ref_or_len >> 1
                    data = self.buf[off:off+n]
                    if n == 16:
                        fields["messageId"] = repr(str(uuid.UUID(bytes=data)))
                    off += n

        except Exception as e:
            fields["_parseError"] = str(e)

        fields_str = ", ".join(f"{k}:{v}" for k, v in list(fields.items())[:8])
        return f"<{alias}>{{{fields_str}}}", off


def _scan_amf3_strings(data: bytes) -> list[str]:
    """
    Escanea bytes AMF3 sin estructura completa buscando strings cortas
    (1-63 bytes, codificadas como U29 de 1 byte: longitud<<1|1, LSB=1).
    Útil para objetos IExternalizable (DSK, DSA, DSE de BlazeDS).
    """
    results = []
    seen = set()
    i = 0
    while i < len(data) - 2:
        b = data[i]
        # U29 de 1 byte con LSB=1: longitud 1..63
        if b & 0x81 == 0x01 and 0x03 <= b <= 0x7F:
            length = b >> 1
            if i + 1 + length <= len(data):
                candidate = data[i + 1 : i + 1 + length]
                try:
                    s = candidate.decode("ascii")
                    if s.isprintable() and s not in seen and len(s) >= 2:
                        results.append(s)
                        seen.add(s)
                        i += 1 + length
                        continue
                except Exception:
                    pass
        i += 1
    return results


# =============================================================================
# AMF0 envelope decoder (con AMF3 embebido)
# =============================================================================

def _amf0_u16(buf: bytes, off: int) -> tuple[int, int]:
    return struct.unpack_from(">H", buf, off)[0], off + 2

def _amf0_i32(buf: bytes, off: int) -> tuple[int, int]:
    return struct.unpack_from(">i", buf, off)[0], off + 4

def _amf0_utf8(buf: bytes, off: int) -> tuple[str, int]:
    n, off = _amf0_u16(buf, off)
    return buf[off : off + n].decode("utf-8", errors="replace"), off + n


def _amf0_value(buf: bytes, off: int, amf3: AMF3Decoder) -> tuple[str, int]:
    """Decodifica un valor AMF0 (puede contener AMF3 via marcador 0x11)."""
    if off >= len(buf):
        return "<eof>", off
    marker = buf[off]; off += 1

    if marker == 0x00:                         # Number
        if off + 8 > len(buf): return "<num:eof>", len(buf)
        v = struct.unpack_from(">d", buf, off)[0]
        return str(v), off + 8

    if marker == 0x01:                         # Boolean
        v = buf[off]; off += 1
        return str(bool(v)), off

    if marker == 0x02:                         # String
        s, off = _amf0_utf8(buf, off)
        return repr(s), off

    if marker == 0x03:                         # Object
        fields = {}
        while off < len(buf):
            key, off = _amf0_utf8(buf, off)
            if off < len(buf) and buf[off] == 0x09:
                off += 1; break
            v, off = _amf0_value(buf, off, amf3)
            fields[key] = v
        return "{" + ", ".join(f"{k}:{v}" for k, v in fields.items()) + "}", off

    if marker == 0x05: return "null", off
    if marker == 0x06: return "undefined", off

    if marker == 0x0A:                         # Array (ECMA)
        count, off = struct.unpack_from(">I", buf, off)[0], off + 4
        items = []
        for _ in range(min(count, 32)):
            v, off = _amf0_value(buf, off, amf3)
            items.append(v)
        return f"[{', '.join(items)}]", off

    if marker == 0x0F:                         # Long String
        n, off = struct.unpack_from(">I", buf, off)[0], off + 4
        s = buf[off : off + n].decode("utf-8", errors="replace")
        return repr(s[:200] + ("…" if n > 200 else "")), off + n

    if marker == 0x11:                         # AMF3 (switch de contexto)
        # Usar el decoder AMF3 compartido para este message body
        v, new_off = amf3.value(off)
        return v, new_off                      # new_off = offset correcto tras el valor AMF3

    return f"<AMF0:0x{marker:02x}>", off


def decode_envelope(body: bytes) -> list[str]:
    """
    Decodifica un envelope AMF0/AMF3 completo.
    Devuelve lista de líneas de texto para impresión.
    """
    lines = []
    if len(body) < 6:
        lines.append("  [respuesta demasiado corta para ser AMF]")
        return lines

    amf3 = AMF3Decoder(body)

    try:
        version = struct.unpack_from(">H", body, 0)[0]
        lines.append(f"  versión AMF    : {version}  (0=AMF0, 3=AMF3)")
        off = 2

        hcount, off = _amf0_u16(body, off)
        lines.append(f"  cabeceras      : {hcount}")
        for _ in range(hcount):
            name, off = _amf0_utf8(body, off)
            must = body[off]; off += 1
            _len, off = _amf0_i32(body, off)
            val, off = _amf0_value(body, off, amf3)
            lines.append(f"    '{name}' (must={bool(must)}): {val}")

        mcount, off = _amf0_u16(body, off)
        lines.append(f"  mensajes       : {mcount}")

        for i in range(mcount):
            target, off = _amf0_utf8(body, off)
            response, off = _amf0_utf8(body, off)
            length, off = _amf0_i32(body, off)
            lines.append(f"  ── Mensaje {i+1} ──────────────────────────────────────────────")
            lines.append(f"    target   : {target!r}")
            lines.append(f"    response : {response!r}")
            lines.append(f"    length   : {length}")
            val, off = _amf0_value(body, off, amf3)
            val_s = str(val)
            if len(val_s) > 800: val_s = val_s[:800] + "…"
            lines.append(f"    body     : {val_s}")

    except Exception as e:
        lines.append(f"  [error de decodificación: {e}]")

    return lines


# =============================================================================
# Detección de marcadores de error en el body binario
# =============================================================================

FAULT_MARKERS = [
    b"Send failed", b"Login Error", b"Authentication",
    b"Client.Authentication", b"Server.Authentication",
    b"Channel.Authentication", b"faultCode", b"faultString",
    b"faultDetail", b"DSException", b"FlexClientNotSubscribed",
    b"DSE",   # clase alias de ErrorMessage en BlazeDS
]

def find_fault_markers(data: bytes) -> list[str]:
    found = []
    for m in FAULT_MARKERS:
        idx = data.find(m)
        if idx != -1:
            start = max(0, idx - 20)
            end = min(len(data), idx + len(m) + 60)
            snippet = data[start:end]
            printable = "".join(chr(b) if 32 <= b < 127 else "." for b in snippet)
            found.append(f"  !! '{m.decode()}' @ offset {idx}: …{printable}…")
    return found


def hex_dump(data: bytes, max_bytes: int = 256) -> list[str]:
    lines = []
    trunc = data[:max_bytes]
    for i in range(0, len(trunc), 16):
        chunk = trunc[i:i+16]
        hex_part = " ".join(f"{b:02x}" for b in chunk).ljust(48)
        asc_part = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        lines.append(f"  {i:04x}  {hex_part}  {asc_part}")
    if len(data) > max_bytes:
        lines.append(f"  … ({len(data) - max_bytes} bytes más)")
    return lines


# =============================================================================
# Lectura de flujos mitmproxy
# =============================================================================

def read_flows(path: str):
    try:
        from mitmproxy import io as mio, http
    except ImportError:
        sys.exit("ERROR: 'mitmproxy' no está instalado.\n  pip install mitmproxy")

    flows = []
    with open(path, "rb") as fh:
        reader = mio.FlowReader(fh)
        try:
            for f in reader.stream():
                if isinstance(f, http.HTTPFlow):
                    flows.append(f)
        except Exception as e:
            print(f"  [aviso] lectura interrumpida: {e}", file=sys.stderr)
    return flows


ECUAPASS_HOSTS = {
    "ecuapass.aduana.gob.ec",
    "ventanillaunica.aduana.gob.ec",
    "vuedes.aduana.gob.ec",
}

def is_messagebroker(flow) -> bool:
    return (flow.request.host in ECUAPASS_HOSTS
            and "messagebroker" in flow.request.path)


# =============================================================================
# Presentación
# =============================================================================

def print_flow(flow, idx: int, verbose: bool = False):
    req = flow.request
    resp = flow.response
    if not resp:
        print(f"\n{'='*72}\nFlujo #{idx}  {req.method} {req.pretty_url}  [sin respuesta]")
        return

    ct_req = req.headers.get("content-type", "")
    ct_res = resp.headers.get("content-type", "")
    body = resp.get_content() or b""

    print(f"\n{'='*72}")
    print(f"Flujo #{idx}  {req.method} https://{req.host}{req.path}")
    print(f"  Content-Type req : {ct_req or '—'}")
    print(f"  Status           : {resp.status_code}")
    print(f"  Content-Type res : {ct_res or '—'}")
    print(f"  Tamaño respuesta : {len(body)} bytes")

    faults = find_fault_markers(body)
    if faults:
        print("\n  *** MARCADORES DE ERROR ***")
        for f in faults:
            print(f)

    if "x-amf" in ct_res or "x-amf" in ct_req:
        print("\n  Decodificación AMF:")
        for line in decode_envelope(body):
            print(line)
    elif verbose and len(body) <= 2048:
        print("\n  Hex dump:")
        for line in hex_dump(body):
            print(line)


# =============================================================================
# Main
# =============================================================================

def main():
    verbose = "--verbose" in sys.argv or "-v" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("-")]

    if not args:
        print(__doc__)
        sys.exit(1)

    path = args[0]
    print(f"Leyendo flujos de: {path}")

    flows = read_flows(path)
    print(f"Total flujos       : {len(flows)}")

    mb_flows = [(i + 1, f) for i, f in enumerate(flows) if is_messagebroker(f)]
    print(f"Flujos messagebroker: {len(mb_flows)}")

    if not mb_flows:
        print("\nNo hay tráfico messagebroker. Hosts observados:")
        for h in sorted({f.request.host for f in flows}):
            print(f"  {h}")
        return

    for idx, flow in mb_flows:
        print_flow(flow, idx, verbose=verbose)

    print(f"\n{'='*72}")
    print("Resumen: respuestas pequeñas (< 512 bytes) — candidatas a FaultMessage:")
    any_fault = False
    for idx, flow in mb_flows:
        if flow.response:
            body = flow.response.get_content() or b""
            if len(body) < 512:
                host_short = flow.request.host.replace(".aduana.gob.ec", "")
                path_short = flow.request.path.split("/")[-1] or flow.request.path
                faults = find_fault_markers(body)
                flag = " *** FAULT ***" if faults else ""
                print(f"  #{idx:3d}  {len(body):4d}B  {host_short}/{path_short}{flag}")
                if faults:
                    any_fault = True
    if not any_fault:
        print("  (ninguna contiene marcadores de error conocidos)")


if __name__ == "__main__":
    main()
