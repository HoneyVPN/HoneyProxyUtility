"""No core or external network: guard against known probe framing mistakes."""
import asyncio
import unittest
from geo_route_dns_probe import read_http_body, connect_core, SocksRejected


class Framing(unittest.IsolatedAsyncioTestCase):
    async def test_fragmented_http_body_finishes_without_eof(self):
        reader = asyncio.StreamReader()
        async def feed():
            for data in [b'HTTP/1.1 200 OK\r\nContent-L', b'ength: 6\r\n\r\np', b'ro', b'xy!']:
                reader.feed_data(data)
                await asyncio.sleep(.01)
        task = asyncio.create_task(feed())
        self.assertEqual(await asyncio.wait_for(read_http_body(reader), .5), b'proxy!')
        await task  # Deliberately no EOF: Content-Length is sufficient.

    async def test_oversized_body_rejected_before_read(self):
        reader = asyncio.StreamReader()
        reader.feed_data(b'HTTP/1.1 200 OK\r\nContent-Length: 4097\r\n\r\n')
        with self.assertRaisesRegex(ValueError, '^HTTP_BODY_BOUND$'):
            await read_http_body(reader)

    async def _server(self, auth_good):
        async def handle(reader, writer):
            try:
                await reader.readexactly(3)
                writer.write(b'\x05\x02')
                await writer.drain()
                await reader.readexactly(2 + len('synthetic') + 1 + len('password'))
                writer.write(b'\x01\x00' if auth_good else b'\x01\x01')
                await writer.drain()
                if auth_good:
                    await reader.readexactly(4 + len('default.example.test') + 1 + 2)
                    writer.write(b'\x05\x02\x00\x01\x7f\x00\x00\x01\x00\x00')
                    await writer.drain()
            finally:
                writer.close()
        return await asyncio.start_server(handle, '127.0.0.1', 0)

    async def test_valid_socks_rejection_has_numeric_code(self):
        server = await self._server(True)
        async with server:
            with self.assertRaises(SocksRejected) as caught:
                await connect_core(server.sockets[0].getsockname()[1], 'synthetic', 'password', 'default.example.test', 80)
            self.assertEqual(caught.exception.code, 2)

    async def test_auth_failure_is_never_classified_as_block(self):
        server = await self._server(False)
        async with server:
            with self.assertRaisesRegex(ValueError, '^CORE_AUTH$'):
                await connect_core(server.sockets[0].getsockname()[1], 'synthetic', 'password', 'default.example.test', 80)


if __name__ == '__main__':
    unittest.main()
