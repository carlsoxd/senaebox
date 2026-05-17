#!/usr/bin/env python3
"""
SenaeBox — Addon mitmproxy: BlazeDS session affinity

Root cause del "Send failed - Login Error" intermitente:

  Flash Flex SDK recibe AppendToGatewayUrl (jsessionid con hint de nodo
  BlazeDS "__.vptws21") pero solo lo aplica en el primer request tras
  recibirlo.  Los canales de polling (heartbeats /1/onResult ~cada 30s)
  no heredan el jsessionid → el load balancer distribuye sin afinidad →
  nodo distinto no encuentra la sesión → LoginError.

Este addon:
  1. Parsea el header AMF AppendToGatewayUrl en respuestas BlazeDS
  2. Reinyecta el jsessionid SOLO en heartbeats de polling (request ≤500B)
     Los requests grandes (CONNECT/init de nuevo módulo Flash) se dejan
     pasar sin modificar para que el load balancer asigne nodo libremente.
     Así evitamos anclar la inicialización de un módulo nuevo a un nodo
     lento (vptws11).
"""

import struct
from mitmproxy import ctx, http

ECUAPASS_HOSTS = {
    "ecuapass.aduana.gob.ec",
    "ventanillaunica.aduana.gob.ec",
    "vuedes.aduana.gob.ec",
}

# Los heartbeats de polling BlazeDS son DSC CommandMessage PING: ~100-300B.
# Los requests de inicialización de módulo (CONNECT) son ≥500B.
POLLING_MAX_BODY = 500


def _extract_append_to_gateway_url(body: bytes) -> str:
    """
    Parsea los headers del envelope AMF0 y extrae AppendToGatewayUrl.
    Devuelve el sufijo (ej. ";jsessionid=xxx__.vptws21") o "".
    """
    if len(body) < 6:
        return ""
    try:
        off = 2  # saltar AMF version (2 bytes)
        header_count = struct.unpack_from(">H", body, off)[0]
        off += 2
        for _ in range(header_count):
            name_len = struct.unpack_from(">H", body, off)[0]
            off += 2
            name = body[off : off + name_len].decode("utf-8", errors="replace")
            off += name_len
            off += 1  # must_understand byte
            off += 4  # body length i32 (ignorado)
            if name == "AppendToGatewayUrl":
                # Cuerpo del header: string AMF0 (marcador 0x02 + u16 + bytes)
                if off < len(body) and body[off] == 0x02:
                    off += 1
                    str_len = struct.unpack_from(">H", body, off)[0]
                    off += 2
                    return body[off : off + str_len].decode("utf-8", errors="replace")
                return ""
            else:
                # En la práctica BlazeDS solo envía AppendToGatewayUrl como
                # primer header; saltar headers desconocidos no es necesario.
                return ""
    except Exception:
        pass
    return ""


class BlazeSessionAddon:
    def __init__(self):
        # host → sufijo jsessionid más reciente, ej. ";jsessionid=T1pO0Io...__.vptws21"
        self._sessions: dict = {}

    def response(self, flow: http.HTTPFlow) -> None:
        host = flow.request.host
        if host not in ECUAPASS_HOSTS:
            return
        if "x-amf" not in flow.response.headers.get("content-type", ""):
            return
        body = flow.response.get_content()
        if not body:
            return
        suffix = _extract_append_to_gateway_url(body)
        if not suffix:
            return
        prev = self._sessions.get(host)
        self._sessions[host] = suffix
        if suffix != prev:
            ctx.log.info(f"[blazeds] {host}: jsessionid → {suffix!r}")

    def request(self, flow: http.HTTPFlow) -> None:
        host = flow.request.host
        if host not in ECUAPASS_HOSTS:
            return
        if "messagebroker" not in flow.request.path:
            return
        if "jsessionid" in flow.request.path:
            return
        suffix = self._sessions.get(host, "")
        if not suffix:
            return

        body = flow.request.get_content() or b""
        if len(body) > POLLING_MAX_BODY:
            # Request grande = CONNECT / init de módulo nuevo.
            # El Flex SDK ya gestiona el jsessionid en estos; no interferir.
            ctx.log.debug(
                f"[blazeds] {host}: request grande ({len(body)}B) — sin reinyección"
            )
            return

        flow.request.path = flow.request.path.rstrip("/") + suffix
        ctx.log.info(f"[blazeds] {host}: heartbeat → jsessionid reinyectado")


addons = [BlazeSessionAddon()]
