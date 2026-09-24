#!/usr/bin/env python3
"""Разбор share-ссылок и .ovpn в объекты sing-box 1.14.

    outbound-parse.py vless  LINK
    outbound-parse.py hy2    LINK
    outbound-parse.py ss     LINK
    outbound-parse.py ovpn   FILE [--user U] [--pass P]

Печатает JSON: protocol, kind (outbound|endpoint), server, port, name,
source, warnings, object. Ошибка — текст в stderr и код 1.

sing-box check пропускает пустой uuid, мусорный PEM и short_id длиннее
16 hex (последний роняет sing-box с panic), поэтому всё проверяется здесь.
"""

import base64
import json
import os
import re
import sys
from urllib.parse import unquote, urlsplit

TAG = "proxy"

UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
HOST_RE = re.compile(r"^[0-9A-Za-z._-]+$")
FINGERPRINTS = {
    "chrome", "firefox", "edge", "safari", "360", "qq", "ios", "android",
    "random", "randomized", "chrome_psk", "chrome_psk_shuffle",
    "chrome_padding_psk_shuffle", "chrome_pq", "chrome_pq_psk",
}


class ParseError(Exception):
    pass


def fail(msg):
    raise ParseError(msg)


def query(parts):
    """Параметры ссылки: последнее значение каждого ключа.
    Без parse_qs: он превращает '+' в пробел, а в URI (RFC 3986) это не так —
    ломались бы base64-значения и пароли с '+'."""
    out = {}
    for pair in parts.query.split("&"):
        if not pair:
            continue
        key, _, value = pair.partition("=")
        out[unquote(key)] = unquote(value)
    return out


def check_host(host):
    host = host.strip("[]")
    if not host or not (HOST_RE.match(host) or ":" in host):
        fail(f"некорректный адрес сервера: {host!r}")
    return host


def check_port(value):
    try:
        port = int(value)
    except (TypeError, ValueError):
        fail(f"некорректный порт: {value!r}")
    if not 1 <= port <= 65535:
        fail(f"порт вне диапазона 1-65535: {port}")
    return port


def split_host_port(netloc):
    """host:port с поддержкой IPv6 в скобках. Порт возвращается строкой —
    у Hysteria2 там бывает диапазон, который urlsplit не разбирает."""
    hostport = netloc.rsplit("@", 1)[-1]
    if hostport.startswith("["):
        host, _, rest = hostport[1:].partition("]")
        port = rest[1:] if rest.startswith(":") else ""
    else:
        host, _, port = hostport.rpartition(":")
        if not host:
            host, port = port, ""
    return check_host(host), port


def truthy(value):
    return str(value).lower() in ("1", "true", "yes")


def result(protocol, kind, server, port, name, source, obj, warnings=None):
    return {
        "protocol": protocol,
        "kind": kind,
        "server": server,
        "port": port,
        "name": name,
        "source": source,
        "warnings": warnings or [],
        "object": obj,
    }


# ===== VLESS =====

def parse_vless(link):
    parts = urlsplit(link.strip())
    if parts.scheme != "vless":
        fail("ожидается ссылка vless://")
    q = query(parts)
    warnings = []
    uuid = unquote(parts.username or "")
    if not UUID_RE.match(uuid):
        fail("UUID в ссылке отсутствует или имеет неверный формат")
    server, port_s = split_host_port(parts.netloc)
    port = check_port(port_s)
    name = unquote(parts.fragment) or server

    enc = q.get("encryption", "none")
    if enc not in ("", "none"):
        # VLESS Encryption (mlkem768x25519plus) есть только в Xray
        fail(f"encryption={enc.split('.')[0]} (VLESS Encryption из Xray) sing-box не поддерживает. "
             "Нужна ссылка с encryption=none — попросите её у провайдера")

    ob = {"type": "vless", "tag": TAG, "server": server, "server_port": port, "uuid": uuid}

    flow = q.get("flow", "")
    if flow not in ("", "xtls-rprx-vision"):
        fail(f"flow={flow} не поддерживается (допустим только xtls-rprx-vision)")
    if flow:
        ob["flow"] = flow

    security = q.get("security", "none")
    if security in ("tls", "reality"):
        tls = {"enabled": True, "server_name": q.get("sni") or q.get("host") or server}
        fp = q.get("fp", "")
        if fp and fp not in FINGERPRINTS:
            fail(f"неизвестный fingerprint fp={fp}")
        if security == "reality":
            # uTLS обязателен для Reality, без него sing-box отказывается стартовать
            tls["utls"] = {"enabled": True, "fingerprint": fp or "chrome"}
            pbk = q.get("pbk", "")
            try:
                raw = base64.urlsafe_b64decode(pbk + "=" * (-len(pbk) % 4))
            except (ValueError, TypeError):
                raw = b""
            if len(raw) != 32:
                fail("pbk (публичный ключ Reality) отсутствует или имеет неверный формат")
            sid = q.get("sid", "")
            if sid and (not re.fullmatch(r"[0-9a-fA-F]*", sid) or len(sid) % 2 or len(sid) > 16):
                fail("sid (short_id) должен быть hex чётной длины, не длиннее 16 символов")
            if not q.get("sni"):
                fail("для Reality в ссылке нужен sni")
            tls["reality"] = {"enabled": True, "public_key": pbk, "short_id": sid}
            if q.get("pqv"):
                warnings.append("pqv (ML-DSA-65) sing-box не поддерживает — "
                                "дополнительная проверка подписи Reality пропущена")
        elif fp:
            tls["utls"] = {"enabled": True, "fingerprint": fp}
        if q.get("alpn"):
            tls["alpn"] = [a for a in q["alpn"].split(",") if a]
        if truthy(q.get("allowInsecure", "")) or truthy(q.get("insecure", "")):
            tls["insecure"] = True
        ob["tls"] = tls
    elif security != "none":
        fail(f"security={security} не поддерживается")

    net = q.get("type", "tcp")
    if net == "tcp":
        if q.get("headerType", "none") not in ("", "none"):
            fail("tcp с headerType=http не поддерживается sing-box")
    elif net == "ws":
        path = q.get("path", "/")
        transport = {"type": "ws", "path": path}
        m = re.search(r"[?&]ed=(\d+)", path)
        if m:
            transport["path"] = re.sub(r"[?&]ed=\d+", "", path) or "/"
            transport["max_early_data"] = int(m.group(1))
            transport["early_data_header_name"] = "Sec-WebSocket-Protocol"
        if q.get("host"):
            transport["headers"] = {"Host": q["host"]}
        ob["transport"] = transport
    elif net == "grpc":
        ob["transport"] = {"type": "grpc", "service_name": q.get("serviceName", "")}
    elif net == "httpupgrade":
        transport = {"type": "httpupgrade", "path": q.get("path", "/")}
        if q.get("host"):
            transport["host"] = q["host"]
        ob["transport"] = transport
    elif net in ("http", "h2"):
        transport = {"type": "http", "path": q.get("path", "/")}
        if q.get("host"):
            transport["host"] = q["host"].split(",")
        ob["transport"] = transport
    else:
        fail(f"транспорт type={net} не поддерживается")

    # Vision работает только поверх голого TCP
    if flow and net != "tcp":
        fail(f"flow={flow} работает только с type=tcp, в ссылке type={net}")

    if q.get("packetEncoding"):
        if q["packetEncoding"] not in ("packetaddr", "xudp"):
            fail(f"packetEncoding={q['packetEncoding']} не поддерживается")
        ob["packet_encoding"] = q["packetEncoding"]

    return result("vless", "outbound", server, port, name, link.strip(), ob, warnings)


# ===== Hysteria2 =====

def hy2_port_ranges(spec):
    """'443' | '20000-30000' | '443,20000-30000' → список "a:b" для sing-box.
    sing-box принимает диапазон только через двоеточие, одиночный — как N:N."""
    ranges = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        lo, _, hi = part.replace(":", "-").partition("-")
        lo = check_port(lo)
        hi = check_port(hi) if hi else lo
        if hi < lo:
            fail(f"неверный диапазон портов: {part}")
        ranges.append(f"{lo}:{hi}")
    return ranges


def parse_hy2(link):
    link = link.strip()
    parts = urlsplit(link)
    if parts.scheme not in ("hy2", "hysteria2"):
        fail("ожидается ссылка hy2:// или hysteria2://")
    q = query(parts)
    userinfo = parts.netloc.rsplit("@", 1)[0] if "@" in parts.netloc else ""
    password = unquote(userinfo)
    if not password:
        fail("в ссылке нет пароля")
    server, port_s = split_host_port(parts.netloc)
    name = unquote(parts.fragment) or server
    warnings = []

    ob = {"type": "hysteria2", "tag": TAG, "server": server, "password": password}

    port = None
    ranges = hy2_port_ranges(q["mport"]) if q.get("mport") else []
    if port_s and re.fullmatch(r"\d+", port_s):
        port = check_port(port_s)
        ob["server_port"] = port
    elif port_s:
        ranges = hy2_port_ranges(port_s) + ranges
    if ranges:
        ob["server_ports"] = ranges
    if port is None and not ranges:
        port = 443
        ob["server_port"] = port

    tls = {"enabled": True, "server_name": q.get("sni") or server}
    if q.get("alpn"):
        tls["alpn"] = [a for a in q["alpn"].split(",") if a]
    if truthy(q.get("insecure", "")):
        tls["insecure"] = True
    # spki= — расширение warperslave: base64 SHA-256 публичного ключа
    # сертификата, пиннинг через certificate_public_key_sha256.
    # Стандартный pinSHA256 (hex отпечатка сертификата) в это поле не
    # переводится — sing-box ждёт хэш ключа, а не сертификата.
    if q.get("spki"):
        try:
            if len(base64.b64decode(q["spki"], validate=True)) != 32:
                raise ValueError
        except ValueError:
            fail("spki должен быть base64 от SHA-256 (32 байта)")
        # Пин проверяется sing-box сам, флаг insecure при нём лишний
        tls.pop("insecure", None)
        tls["certificate_public_key_sha256"] = [q["spki"]]
    elif tls.get("insecure"):
        warnings.append("insecure=1 без пиннинга: сертификат сервера не проверяется")
    ob["tls"] = tls

    obfs = q.get("obfs", "")
    if obfs:
        if obfs != "salamander":
            fail(f"obfs={obfs} не поддерживается (допустим salamander)")
        if not q.get("obfs-password"):
            fail("obfs=salamander без obfs-password")
        ob["obfs"] = {"type": "salamander", "password": q["obfs-password"]}

    for src, dst in (("upmbps", "up_mbps"), ("downmbps", "down_mbps")):
        if q.get(src):
            try:
                ob[dst] = int(q[src])
            except ValueError:
                fail(f"{src} должен быть числом")

    return result("hy2", "outbound", server, port, name, link, ob, warnings)


# ===== Shadowsocks (связка с warperslave) =====

def parse_ss(link):
    link = link.strip()
    parts = urlsplit(link)
    if parts.scheme != "ss":
        fail("ожидается ссылка ss://")
    name = unquote(parts.fragment)

    def b64(s):
        s = unquote(s)
        return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)).decode()

    if "@" in parts.netloc:
        userinfo, _, hostport = parts.netloc.rpartition("@")
        userinfo = unquote(userinfo)
        if ":" not in userinfo:
            userinfo = b64(userinfo)
    else:
        # Старый формат: base64(method:password@host:port)
        decoded = b64(parts.netloc)
        userinfo, _, hostport = decoded.rpartition("@")
    method, _, password = userinfo.partition(":")
    server, port_s = split_host_port(hostport)
    port = check_port(port_s)
    if not password:
        fail("в ссылке нет пароля")
    # Режим slave собирается из шаблона ровно под этот метод
    if method != "2022-blake3-aes-128-gcm":
        fail(f"метод {method} не поддерживается, связка с донором использует 2022-blake3-aes-128-gcm")
    out = result("ss", "outbound", server, port, name or server, link, None)
    out["password"] = password
    out["method"] = method
    return out


# ===== OpenVPN =====

INLINE_BLOCKS = ("ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2", "secret")
IGNORED = {
    "client", "nobind", "persist-key", "persist-tun", "resolv-retry", "verb",
    "mute", "mute-replay-warnings", "pull", "fast-io", "float", "setenv",
    "script-security", "up", "down", "route-up", "route-pre-down", "dhcp-option",
    "block-outside-dns", "redirect-gateway", "sndbuf", "rcvbuf", "tls-client",
    "auth-nocache", "ignore-unknown-option", "push-peer-info", "user", "group",
    "log", "log-append", "status", "writepid", "connect-retry",
    "connect-retry-max", "server-poll-timeout", "comp-noadapt", "route-delay",
    "route-method", "register-dns", "windows-driver", "ncp-disable",
    "remote-cert-eku",
}


def read_ovpn(path):
    """Директивы и инлайн-блоки .ovpn. Файловые ссылки (ca file.crt)
    читаются относительно каталога конфига."""
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    blocks = {}

    def grab(m):
        blocks[m.group(1)] = m.group(2).strip()
        return ""

    text = re.sub(r"<([a-z0-9-]+)>\s*\n(.*?)\n\s*</\1>", grab, text, flags=re.S)
    directives = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line[0] in "#;":
            continue
        tokens = line.split()
        directives.append((tokens[0].lower(), tokens[1:]))
    return directives, blocks


def ovpn_file(base, name):
    p = name if os.path.isabs(name) else os.path.join(base, name)
    try:
        with open(p, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        fail(f"не найден файл из конфига: {name}")


def pem_list(text):
    return [line for line in text.splitlines() if line.strip()]


def parse_ovpn(path, user=None, password=None):
    if not os.path.isfile(path):
        fail(f"файл не найден: {path}")
    base = os.path.dirname(os.path.abspath(path))
    directives, blocks = read_ovpn(path)
    warnings = []

    ep = {"type": "openvpn-client", "tag": TAG}
    tls = {}
    remotes = []
    default_port = 1194
    default_proto = "udp"
    key_direction = None
    needs_auth = False
    tls_auth_dir = None

    def proto_to_network(proto):
        proto = proto.lower().replace("-client", "")
        if proto not in ("udp", "udp4", "udp6", "tcp", "tcp4", "tcp6"):
            fail(f"proto {proto} не поддерживается")
        return proto

    for name, args in directives:
        if name == "dev":
            if args and args[0].startswith("tap"):
                fail("dev tap не поддерживается sing-box, нужен dev tun")
        elif name == "remote":
            if not args:
                fail("пустая директива remote")
            remotes.append(args)
        elif name == "port" and args:
            default_port = check_port(args[0])
        elif name == "proto" and args:
            default_proto = proto_to_network(args[0])
        elif name == "remote-random":
            ep["remote_random"] = True
        elif name == "cipher" and args:
            # В режиме tls поле cipher запрещено, это fallback для старых серверов
            ep["data_ciphers_fallback"] = args[0].upper()
        elif name in ("data-ciphers", "ncp-ciphers") and args:
            ep["data_ciphers"] = [c.upper() for c in args[0].split(":") if c]
        elif name == "data-ciphers-fallback" and args:
            ep["data_ciphers_fallback"] = args[0].upper()
        elif name == "auth" and args:
            ep["auth"] = args[0].upper()
        elif name == "auth-user-pass":
            needs_auth = True
            # Файл с логином/паролем необязателен: их можно передать аргументами
            if args:
                p = args[0] if os.path.isabs(args[0]) else os.path.join(base, args[0])
                try:
                    with open(p, encoding="utf-8") as f:
                        lines = f.read().splitlines()
                    user = user or (lines[0].strip() if lines else None)
                    password = password or (lines[1].strip() if len(lines) > 1 else None)
                except OSError:
                    pass
        elif name == "auth-retry" and args:
            ep["auth_retry"] = args[0]
        elif name == "key-direction" and args:
            key_direction = args[0]
        elif name == "ca" and args and "ca" not in blocks:
            blocks["ca"] = ovpn_file(base, args[0])
        elif name == "cert" and args and "cert" not in blocks:
            blocks["cert"] = ovpn_file(base, args[0])
        elif name == "key" and args and "key" not in blocks:
            blocks["key"] = ovpn_file(base, args[0])
        elif name == "tls-auth" and args:
            if args[0] != "[inline]" and "tls-auth" not in blocks:
                blocks["tls-auth"] = ovpn_file(base, args[0])
            if len(args) > 1:
                tls_auth_dir = args[-1]
        elif name == "tls-crypt" and args and args[0] != "[inline]" and "tls-crypt" not in blocks:
            blocks["tls-crypt"] = ovpn_file(base, args[0])
        elif name == "tls-crypt-v2" and args and args[0] != "[inline]" and "tls-crypt-v2" not in blocks:
            blocks["tls-crypt-v2"] = ovpn_file(base, args[0])
        elif name in ("secret",):
            fail("режим static key (secret) не поддерживается, нужен конфиг с сертификатами")
        elif name == "pkcs12":
            fail("pkcs12 не поддерживается, нужны отдельные <ca>/<cert>/<key>")
        elif name in ("http-proxy", "socks-proxy"):
            fail(f"{name} не поддерживается")
        elif name == "verify-x509-name" and args:
            tls["server_name"] = args[0].strip("'\"")
            if len(args) > 1:
                tls["server_name_type"] = args[1]
        elif name == "remote-cert-tls" and args:
            tls["remote_certificate_tls"] = args[0]
        elif name == "ns-cert-type" and args:
            tls["ns_certificate_type"] = args[0]
        elif name == "tls-version-min" and args:
            tls["version_min"] = args[0]
        elif name == "tls-version-max" and args:
            tls["version_max"] = args[0]
        elif name == "tls-cipher" and args:
            tls["cipher"] = args[0]
        elif name == "tls-groups" and args:
            tls["groups"] = args[0]
        elif name == "tls-cert-profile" and args:
            tls["certificate_profile"] = args[0]
        elif name == "peer-fingerprint" and args:
            tls["peer_fingerprint"] = args
        elif name == "compress":
            ep["compression"] = args[0] if args else "stub"
        elif name == "comp-lzo":
            ep["compression_lzo"] = args[0] if args else "adaptive"
        elif name == "allow-compression" and args:
            ep["allow_compression"] = args[0]
        elif name == "tun-mtu" and args:
            ep["mtu"] = int(args[0])
        elif name == "mssfix":
            if args and args[0] == "0":
                ep["mss_fix_disabled"] = True
            elif args:
                ep["mss_fix"] = int(args[0])
        elif name == "fragment" and args:
            ep["fragment"] = int(args[0])
        elif name == "ping" and args:
            ep["ping_interval"] = f"{int(args[0])}s"
        elif name == "ping-restart" and args:
            ep["ping_restart"] = f"{int(args[0])}s"
        elif name == "reneg-sec" and args:
            if args[0] == "0":
                ep["renegotiate_disabled"] = True
            else:
                ep["renegotiate_interval"] = f"{int(args[0])}s"
        elif name == "hand-window" and args:
            ep["handshake_window"] = f"{int(args[0])}s"
        elif name == "tls-timeout" and args:
            ep["tls_timeout"] = f"{int(args[0])}s"
        elif name == "explicit-exit-notify":
            ep["explicit_exit_notify"] = int(args[0]) if args else 1
        elif name == "block-ipv6":
            ep["block_ipv6"] = True
        elif name == "static-challenge" and args:
            fail("static-challenge (одноразовые коды) не поддерживается при неинтерактивном запуске")
        elif name not in IGNORED:
            warnings.append(f"директива {name} проигнорирована")

    if not remotes:
        fail("в конфиге нет ни одной директивы remote")
    servers = []
    for args in remotes:
        host = check_host(args[0])
        port = check_port(args[1]) if len(args) > 1 else default_port
        network = proto_to_network(args[2]) if len(args) > 2 else default_proto
        servers.append({"server": host, "server_port": port, "network": network})

    if len(servers) == 1:
        ep["server"] = servers[0]["server"]
        ep["server_port"] = servers[0]["server_port"]
        ep["network"] = servers[0]["network"]
    else:
        ep["servers"] = servers

    if "ca" not in blocks and "peer_fingerprint" not in tls:
        fail("нет сертификата CA (<ca> или ca file)")
    if "ca" in blocks:
        tls["certificate"] = pem_list(blocks["ca"])
    if "cert" in blocks:
        tls["client_certificate"] = pem_list(blocks["cert"])
    if "key" in blocks:
        tls["client_key"] = pem_list(blocks["key"])
    if ("cert" in blocks) != ("key" in blocks):
        fail("клиентский сертификат и ключ должны быть заданы вместе")

    for kind, typ in (("tls-crypt-v2", "tls_crypt_v2"), ("tls-crypt", "tls_crypt"), ("tls-auth", "tls_auth")):
        if kind in blocks:
            wrap = {"type": typ, "key": pem_list(blocks[kind])}
            if typ == "tls_auth":
                d = tls_auth_dir if tls_auth_dir is not None else key_direction
                if d is not None:
                    wrap["direction"] = "client" if d == "1" else "server"
            tls["control_wrap"] = wrap
            break
    ep["tls"] = tls

    if needs_auth:
        if not user or not password:
            fail("конфиг требует логин и пароль (auth-user-pass): передайте их отдельно")
        ep["username"] = user
        ep["password"] = password
    elif "cert" not in blocks:
        fail("нет ни клиентского сертификата, ни auth-user-pass — аутентификация невозможна")

    first = servers[0]
    name = os.path.splitext(os.path.basename(path))[0]
    return result("openvpn", "endpoint", first["server"], first["server_port"],
                  name, os.path.abspath(path), ep, warnings)


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    kind, target = argv[1], argv[2]
    try:
        if kind == "vless":
            out = parse_vless(target)
        elif kind == "hy2":
            out = parse_hy2(target)
        elif kind == "ss":
            out = parse_ss(target)
        elif kind == "ovpn":
            user = password = None
            rest = argv[3:]
            while rest:
                if rest[0] == "--user" and len(rest) > 1:
                    user, rest = rest[1], rest[2:]
                elif rest[0] == "--pass" and len(rest) > 1:
                    password, rest = rest[1], rest[2:]
                else:
                    fail(f"неизвестный аргумент {rest[0]}")
            out = parse_ovpn(target, user, password)
        else:
            fail(f"неизвестный тип {kind}")
    except ParseError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    except (ValueError, UnicodeDecodeError) as e:
        print(f"ERROR: не удалось разобрать: {e}", file=sys.stderr)
        return 1
    json.dump(out, sys.stdout, ensure_ascii=False)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
