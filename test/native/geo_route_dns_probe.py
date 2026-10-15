"""Synthetic loopback-only route/DoH proof. No TUN, OS proxy, real peers or logs.

The exact app-generated route and DNS policy come from the Dart export fixture.
Only listeners, two spy outbounds and an explicitly trusted artificial DoH TLS
certificate are rebound. Every permitted TCP dial is to our exact loopback DoH
port. All other SOCKS targets are matched as bytes and answered locally.
"""
import argparse
import asyncio
import base64
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import struct
import subprocess
import tempfile
import time
import urllib.parse

WEB_TARGETS = {'blocked.example.test', 'proxy.example.test', 'direct.example.test',
               'default.example.test', '2.16.20.1', '2001:470:5:5c::1'}
PHASE = {'phase': 'INPUTS', 'case': None}
QUERY = b'\x13\x37\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x09synthetic\x07example\x04test\x00\x00\x01\x00\x01'


def require(ok, code):
    if not ok:
        raise ValueError(code)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def plain(path):
    path = path.absolute()
    require(path.is_file(), 'FILE_REQUIRED')
    for parent in [path, *path.parents]:
        require(not parent.is_symlink() and not (getattr(parent.lstat(), 'st_file_attributes', 0) & 1024), 'REPARSE')
    return path


def read_packet(path, bound):
    path = plain(path)
    require(path.stat().st_size <= bound, 'FILE_BOUND')
    return path.read_bytes()


async def exact(reader, count):
    return await asyncio.wait_for(reader.readexactly(count), 5)


class SocksRejected(Exception):
    def __init__(self, code):
        self.code = code


async def read_http_body(reader):
    headers = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 5)
    require(len(headers) <= 8192 and headers.startswith(b'HTTP/1.1 200 '), 'HTTP_HEADERS')
    lengths = [line.split(b':', 1)[1].strip() for line in headers.split(b'\r\n')
               if line.lower().startswith(b'content-length:')]
    require(len(lengths) == 1 and lengths[0].isdigit(), 'HTTP_LENGTH')
    size = int(lengths[0])
    require(0 < size <= 4096, 'HTTP_BODY_BOUND')
    return await exact(reader, size)


async def target(reader, kind):
    if kind == 1:
        return str(ipaddress.ip_address(await exact(reader, 4)))
    if kind == 4:
        return str(ipaddress.ip_address(await exact(reader, 16)))
    require(kind == 3, 'SOCKS_TYPE')
    size = (await exact(reader, 1))[0]
    return (await exact(reader, size)).decode('ascii')


def address(value):
    try:
        ip = ipaddress.ip_address(value)
        return bytes([1 if ip.version == 4 else 4]) + ip.packed
    except ValueError:
        b = value.encode('ascii')
        return b'\x03' + bytes([len(b)]) + b


class Fixture:
    def __init__(self):
        self.web = {'direct': 0, 'proxy': 0}
        self.dns_relays = 0
        self.dns_queries = 0
        self.unexpected = 0
        self.last_error = None
        self.tasks = set()
        self.writers = set()
        self.dns_port = 0

    async def handler(self, role, reader, writer):
        task = asyncio.current_task()
        self.tasks.add(task)
        self.writers.add(writer)
        try:
            async with asyncio.timeout(12):
                if role == 'dns':
                    await self.doh(reader, writer)
                    return
                version, size = await exact(reader, 2)
                require(version == 5 and size <= 8, 'SINK_GREETING')
                require(0 in await exact(reader, size), 'SINK_AUTH')
                writer.write(b'\x05\x00')
                await writer.drain()
                header = await exact(reader, 4)
                require(header[:3] == b'\x05\x01\x00', 'SINK_CONNECT')
                dest = await target(reader, header[3])
                port = struct.unpack('!H', await exact(reader, 2))[0]
                if dest == '127.0.0.1' and port == self.dns_port and role == 'proxy':
                    self.dns_relays += 1
                    upstream_reader, upstream_writer = await asyncio.open_connection('127.0.0.1', self.dns_port)
                    self.writers.add(upstream_writer)
                    writer.write(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00')
                    await writer.drain()
                    async def pipe(src, dst):
                        while True:
                            data = await src.read(16384)
                            if not data:
                                break
                            dst.write(data)
                            await dst.drain()
                    pipes = [asyncio.create_task(pipe(reader, upstream_writer)), asyncio.create_task(pipe(upstream_reader, writer))]
                    try:
                        await asyncio.wait(pipes, return_when=asyncio.FIRST_COMPLETED)
                    finally:
                        for p in pipes:
                            p.cancel()
                        await asyncio.gather(*pipes, return_exceptions=True)
                        upstream_writer.close()
                        self.writers.discard(upstream_writer)
                    return
                require(dest in WEB_TARGETS and port == 80, 'SINK_TARGET')
                self.web[role] += 1
                writer.write(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00')
                await writer.drain()
                request = await reader.readuntil(b'\r\n\r\n')
                require(len(request) <= 4096 and request.startswith(b'GET / HTTP/1.1\r\n'), 'SINK_HTTP')
                body = role.encode('ascii')
                writer.write(b'HTTP/1.1 200 OK\r\nContent-Length: ' + str(len(body)).encode() + b'\r\nConnection: close\r\n\r\n' + body)
                await writer.drain()
        except (asyncio.CancelledError, asyncio.IncompleteReadError, ConnectionResetError):
            pass
        except Exception as error:
            self.unexpected += 1
            self.last_error = str(error) if type(error) is ValueError and str(error).isupper() and str(error).replace('_', '').isalpha() else type(error).__name__
        finally:
            writer.close()
            self.writers.discard(writer)
            self.tasks.discard(task)

    async def doh(self, reader, writer):
        headers = await reader.readuntil(b'\r\n\r\n')
        require(len(headers) <= 8192, 'DOH_HEADERS')
        lines = headers.decode('ascii').split('\r\n')
        method, path, _ = lines[0].split(' ')
        values = dict(line.split(': ', 1) for line in lines[1:] if ': ' in line)
        if method == 'POST':
            size = int(next(v for k, v in values.items() if k.lower() == 'content-length'))
            require(12 <= size <= 512, 'DOH_BODY')
            query = await exact(reader, size)
        else:
            require(method == 'GET', 'DOH_METHOD')
            encoded = urllib.parse.parse_qs(urllib.parse.urlparse(path).query)['dns'][0]
            query = base64.urlsafe_b64decode(encoded + '=' * (-len(encoded) % 4))
        require(len(query) <= 512 and query[4:6] == b'\x00\x01', 'DOH_QUESTION_COUNT')
        at, labels = 12, []
        while at < len(query) and query[at] != 0:
            size = query[at]
            require(0 < size <= 63 and at + size < len(query), 'DOH_QUESTION_LABEL')
            labels.append(query[at + 1:at + size + 1].decode('ascii').lower())
            at += size + 1
        end = at + 5
        require('.'.join(labels) == 'synthetic.example.test' and query[at:end] == b'\x00\x00\x01\x00\x01', 'DOH_QUESTION')
        self.dns_queries += 1
        # Return only the validated question and answer; an EDNS option/padding
        # added by the actual resolver is neither echoed nor required absent.
        answer = query[:2] + b'\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00' + query[12:end] + b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x01\x00\x04\xc6\x33\x64\x09'
        writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: application/dns-message\r\nContent-Length: ' + str(len(answer)).encode() + b'\r\nConnection: close\r\n\r\n' + answer)
        await writer.drain()


async def connect_core(port, username, password, dest, dest_port):
    reader, writer = await asyncio.wait_for(asyncio.open_connection('127.0.0.1', port), 1)
    try:
        writer.write(b'\x05\x01\x02')
        await writer.drain()
        require(await exact(reader, 2) == b'\x05\x02', 'CORE_AUTH_MODE')
        u, p = username.encode(), password.encode()
        writer.write(b'\x01' + bytes([len(u)]) + u + bytes([len(p)]) + p)
        await writer.drain()
        require(await exact(reader, 2) == b'\x01\x00', 'CORE_AUTH')
        writer.write(b'\x05\x01\x00' + address(dest) + struct.pack('!H', dest_port))
        await writer.drain()
        reply = await exact(reader, 4)
        require(reply[0] == 5 and reply[2] == 0 and 0 <= reply[1] <= 8, 'CORE_CONNECT')
        await target(reader, reply[3])
        await exact(reader, 2)
        if reply[1] != 0:
            raise SocksRejected(reply[1])
        return reader, writer
    except BaseException:
        writer.close()
        raise


async def main(args):
    core = plain(Path(args.core))
    require(sha(core) == args.core_sha256, 'CORE_PIN')
    fixture_root = Path(args.fixtures).absolute()
    manifest_bytes = read_packet(fixture_root / 'manifest.json', 32768)
    require(hashlib.sha256(manifest_bytes).hexdigest() == args.manifest_sha256, 'MANIFEST_PIN')
    manifest = json.loads(manifest_bytes)
    require(manifest['schema'] == 1 and manifest['syntheticOnly'] is True and len(manifest['cases']) == 10, 'MANIFEST_SCHEMA')
    for f in manifest['files']:
        require('..' not in f['name'] and not Path(f['name']).is_absolute(), 'INPUT_NAME')
        path = plain(fixture_root / f['name'])
        require(path.stat().st_size == f['bytes'] and sha(path) == f['sha256'], 'INPUT_PIN')
    cert, key = plain(Path(args.cert)), plain(Path(args.key))
    require(cert.parent == fixture_root and key.parent == fixture_root and cert.name == 'synthetic-cert.pem' and key.name == 'synthetic-key.pem', 'SYNTHETIC_TLS_SCOPE')
    require({cert.name, key.name}.issubset({v['name'] for v in manifest['files']}), 'TLS_PIN_REQUIRED')
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.set_alpn_protocols(['http/1.1'])
    context.load_cert_chain(cert, key)
    f = Fixture()
    servers = []
    results = []
    all_exited = True
    environment = {k: v for k, v in os.environ.items() if not k.startswith('ENABLE_DEPRECATED_')}
    try:
        for role in ['dns', 'direct', 'proxy']:
            server = await asyncio.start_server(lambda r, w, role=role: f.handler(role, r, w), '127.0.0.1', 0, ssl=context if role == 'dns' else None, limit=16384)
            servers.append(server)
        f.dns_port, direct_port, proxy_port = [s.sockets[0].getsockname()[1] for s in servers]
        with tempfile.TemporaryDirectory(prefix='honey-owned-geo-probe-') as temporary:
            for row in manifest['cases']:
                PHASE.update(phase='CONFIG', case=row['id'])
                config = json.loads(read_packet(fixture_root / row['file'], 65536))
                require(not config.get('endpoints') and config['route']['final'] == 'proxy', 'CONFIG_SCOPE')
                require(config['dns']['final'] == 'remote', 'DNS_FINAL')
                remote = next(s for s in config['dns']['servers'] if s['tag'] == 'remote')
                require(remote['type'] == 'https' and remote['server'] == '127.0.0.1' and remote['detour'] == 'proxy', 'DNS_POLICY')
                remote['server_port'] = f.dns_port
                remote['tls'] = {'enabled': True, 'certificate_path': str(cert)}
                with socket.socket() as reservation:
                    reservation.bind(('127.0.0.1', 0))
                    inbound_port = reservation.getsockname()[1]
                username, password = 'synthetic', secrets.token_hex(16)
                config['inbounds'] = [{'type': 'socks', 'tag': 'socks-in', 'listen': '127.0.0.1', 'listen_port': inbound_port, 'users': [{'username': username, 'password': password}]}]
                config['outbounds'] = [{'type': 'socks', 'tag': role, 'server': '127.0.0.1', 'server_port': port} for role, port in [('direct', direct_port), ('proxy', proxy_port)]]
                config.pop('experimental', None)
                config['log'] = {'disabled': True}
                for rule in config['route'].get('rule_set', []):
                    if rule['type'] == 'local':
                        require(rule['path'].startswith('geo/'), 'GEO_PATH')
                        rule['path'] = str(plain(fixture_root / rule['path']))
                path = Path(temporary) / (row['id'] + '.json')
                path.write_text(json.dumps(config), encoding='utf-8')
                PHASE['phase'] = 'CORE_CHECK'
                checked = subprocess.run([str(core), 'check', '-c', str(path)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20, env=environment)
                require(checked.returncode == 0, 'CORE_CHECK')
                before = dict(f.web)
                queries, relays = f.dns_queries, f.dns_relays
                PHASE['phase'] = 'CORE_START'
                process = subprocess.Popen([str(core), 'run', '-c', str(path)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=environment)
                writer = None
                try:
                    deadline = time.monotonic() + 10
                    rejected = None
                    while True:
                        require(process.poll() is None, 'CORE_EXITED')
                        try:
                            reader, writer = await connect_core(inbound_port, username, password, row['target'], 53 if row['expected'] == 'dns' else 80)
                            break
                        except SocksRejected as rejection:
                            require(row['expected'] == 'block', 'UNEXPECTED_SOCKS_REJECTION')
                            rejected = rejection.code
                            break
                        except ConnectionRefusedError:
                            require(time.monotonic() < deadline, 'CORE_START_TIMEOUT')
                            await asyncio.sleep(.05)
                    PHASE['phase'] = 'REQUEST'
                    try:
                        if rejected is not None:
                            actual = 'block'
                        elif row['expected'] == 'dns':
                            writer.write(struct.pack('!H', len(QUERY)) + QUERY)
                            await writer.drain()
                            size = struct.unpack('!H', await exact(reader, 2))[0]
                            response = await exact(reader, size)
                            require(response[:2] == QUERY[:2] and response[3] & 15 == 0 and response[-4:] == b'\xc6\x33\x64\x09', 'DNS_ANSWER')
                            actual = 'dns'
                        else:
                            writer.write(b'GET / HTTP/1.1\r\nHost: ' + row['target'].encode('ascii') + b'\r\nConnection: close\r\n\r\n')
                            await writer.drain()
                            response = await read_http_body(reader)
                            actual = response.decode('ascii')
                    except (asyncio.IncompleteReadError, ConnectionResetError):
                        actual = 'block'
                    PHASE.update(observed=actual if actual in {'block', 'proxy', 'direct', 'dns'} else 'invalid', dohQueries=f.dns_queries, dohRelays=f.dns_relays, sinkErrors=f.unexpected, sinkErrorCode=f.last_error)
                    require(actual == row['expected'], 'ROUTE_OUTCOME')
                    await asyncio.sleep(.05)
                    delta = {k: f.web[k] - before[k] for k in before}
                    require(delta == {'direct': int(actual == 'direct'), 'proxy': int(actual == 'proxy')}, 'SINK_COUNTS')
                    if actual == 'dns':
                        require(f.dns_queries > queries and f.dns_relays > relays, 'DNS_PROXY_TRACE')
                    require(f.unexpected == 0, 'UNEXPECTED_TARGET_OR_PROTOCOL')
                    healthy_control = None
                    if actual == 'block':
                        require(process.poll() is None, 'BLOCK_CORE_NOT_ALIVE')
                        control_reader, control_writer = await connect_core(inbound_port, username, password, 'default.example.test', 80)
                        try:
                            control_writer.write(b'GET / HTTP/1.1\r\nHost: default.example.test\r\nConnection: close\r\n\r\n')
                            await control_writer.drain()
                            healthy_control = (await read_http_body(control_reader)).decode('ascii')
                            require(healthy_control == 'proxy', 'BLOCK_HEALTHY_CONTROL')
                        finally:
                            control_writer.close()
                    results.append({'id': row['id'], 'expected': row['expected'], 'actual': actual, 'directWeb': delta['direct'], 'proxyWeb': delta['proxy'], 'dohQueries': f.dns_queries - queries, 'proxyDohRelays': f.dns_relays - relays, 'socksRejectCode': rejected, 'blockedHealthyControl': healthy_control, 'passed': True})
                finally:
                    if writer is not None:
                        writer.close()
                    if process.poll() is None:
                        process.terminate()
                    try:
                        await asyncio.to_thread(process.wait, 5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        await asyncio.to_thread(process.wait, 5)
                    all_exited = all_exited and process.poll() is not None
        require(all_exited and len(results) == 10, 'OWNED_COMPLETION')
    finally:
        for server in servers:
            server.close()
            await server.wait_closed()
        for writer in list(f.writers):
            writer.close()
        for task in list(f.tasks):
            task.cancel()
        if f.tasks:
            await asyncio.gather(*list(f.tasks), return_exceptions=True)
    result = {'schema': 1, 'status': 'SYNTHETIC_PROXY_ROUTE_AND_DOH_PASS', 'coreSHA256': args.core_sha256, 'manifestSHA256': args.manifest_sha256, 'cases': results, 'ownedCoreProcessesExited': all_exited, 'ownedServersAndHandlersClosed': not f.tasks, 'onlyLoopbackDialsImplemented': True, 'tunStarted': False, 'osProxyRoutesOrTrustStoreModified': False, 'actualVpnProtocolHandshakeProven': False}
    require(result['ownedServersAndHandlersClosed'], 'HANDLER_RETIREMENT')
    with Path(args.output).open('x', encoding='utf-8') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print(json.dumps({'status': result['status'], 'casesPassed': len(results), 'coreSHA256': args.core_sha256}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ['core', 'core-sha256', 'fixtures', 'manifest-sha256', 'cert', 'key', 'output']:
        parser.add_argument('--' + arg, required=True)
    args = parser.parse_args()
    try:
        asyncio.run(asyncio.wait_for(main(args), 180))
    except Exception as error:
        code = str(error) if type(error) is ValueError and str(error).isupper() and str(error).replace('_', '').isalpha() else type(error).__name__
        print(json.dumps({'status': 'SYNTHETIC_PROBE_STOPPED', 'reason': code, 'rawCoreLogsRead': False, **PHASE}))
        raise SystemExit(1) from None
