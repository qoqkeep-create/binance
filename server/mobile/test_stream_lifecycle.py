import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

from django.test import SimpleTestCase

from mobile import account_stream


async def inline_thread(function, *args, **kwargs):
    return function(*args, **kwargs)


class AccountStreamLifecycleTests(SimpleTestCase):
    def setUp(self):
        self.binding = SimpleNamespace(pk=17)
        self.clock = SimpleNamespace(now=0)
        self.client = Mock()
        self.client._request.return_value = {"listenKey": "test-listen-key"}
        self.account = Mock()
        self.account.create_futures_client.return_value = self.client
        self.socket = SimpleNamespace(recv=AsyncMock(side_effect=ConnectionError))
        self.context = Mock()
        self.context.__aenter__ = AsyncMock(return_value=self.socket)
        self.context.__aexit__ = AsyncMock(return_value=False)
        self.upstream = Mock()
        self.upstream.reserve_connection.return_value = 0
        self.upstream.rotation_seconds.return_value = 23 * 3600
        self.upstream.defer_handshake.return_value = 0
        self.upstream.reconnect_delay.side_effect = lambda attempt: attempt
        self.runtime = Mock(wraps=asyncio)
        self.runtime.to_thread = inline_thread
        self.runtime.sleep = AsyncMock(side_effect=asyncio.CancelledError)
        self.runtime.CancelledError = asyncio.CancelledError
        self.runtime.TimeoutError = asyncio.TimeoutError
        for target, value in (
            ("asyncio", self.runtime), ("upstream", self.upstream),
            ("time", SimpleNamespace(monotonic=lambda: self.clock.now, time=lambda: 1000 + self.clock.now)),
            ("account_for", Mock(return_value=self.account)),
            ("connect", Mock(return_value=self.context)), ("ingest", Mock()),
        ):
            replacement = patch.object(account_stream, target, value, create=True)
            replacement.start()
            self.addCleanup(replacement.stop)

    async def test_admission_wait_does_not_create_listen_key_or_reconcile(self):
        self.upstream.reserve_connection.return_value = 30
        with self.assertRaises(asyncio.CancelledError):
            await account_stream._consume(self.binding)
        self.runtime.sleep.assert_awaited_once_with(30)
        account_stream.account_for.assert_not_called()
        self.client._request.assert_not_called()
        account_stream.connect.assert_not_called()
        account_stream.ingest.assert_not_called()

    async def test_short_connections_keep_increasing_backoff(self):
        delays = []

        async def sleep(delay):
            delays.append(delay)
            if len(delays) == 3:
                raise asyncio.CancelledError

        self.runtime.sleep.side_effect = sleep
        with self.assertRaises(asyncio.CancelledError):
            await account_stream._consume(self.binding)
        self.assertEqual(delays, [1, 2, 3])
        self.assertEqual(self.upstream.reserve_connection.call_count, 3)
        self.assertEqual(account_stream.ingest.call_count, 6)
        self.assertEqual(self.context.__aexit__.await_count, 3)

    async def test_handshake_cooldown_does_not_enqueue_account_reconcile_or_log_key(self):
        self.context.__aenter__.side_effect = ConnectionError("private-url/test-listen-key")
        self.upstream.defer_handshake.return_value = 120
        with self.assertLogs("mobile.account_stream", level="WARNING") as logs:
            with self.assertRaises(asyncio.CancelledError):
                await account_stream._consume(self.binding)
        self.runtime.sleep.assert_awaited_once_with(120)
        account_stream.ingest.assert_not_called()
        self.assertNotIn("test-listen-key", " ".join(logs.output))

    async def test_rotation_closes_before_new_admission_without_failure_backoff(self):
        self.upstream.rotation_seconds.return_value = 1
        self.upstream.reserve_connection.side_effect = [0, asyncio.CancelledError]

        async def receive():
            self.clock.now = 2
            return '{"e":"ACCOUNT_UPDATE","a":{"B":[]}}'

        self.socket.recv.side_effect = receive
        with self.assertRaises(asyncio.CancelledError):
            await account_stream._consume(self.binding)
        self.context.__aexit__.assert_awaited_once()
        self.upstream.reconnect_delay.assert_not_called()
        self.runtime.sleep.assert_not_awaited()
        self.assertEqual(account_stream.ingest.call_count, 3)

    async def test_listen_key_keepalive_continues_on_healthy_connection(self):
        calls = 0

        async def receive():
            nonlocal calls
            calls += 1
            if calls > 1:
                raise asyncio.CancelledError
            self.clock.now = 1801
            return '{"e":"ACCOUNT_UPDATE","a":{"B":[]}}'

        self.socket.recv.side_effect = receive
        with self.assertRaises(asyncio.CancelledError):
            await account_stream._consume(self.binding)
        self.assertEqual([call.args[:2] for call in self.client._request.call_args_list],
                         [("POST", "/fapi/v1/listenKey"), ("PUT", "/fapi/v1/listenKey")])

    async def test_lease_loss_cancels_open_stream_and_releases_lease(self):
        entered, cancelled = asyncio.Event(), asyncio.Event()
        lease = Mock()
        lease.acquire.return_value = True

        async def consume(_binding):
            entered.set()
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()

        async def renew(_binding, _lease):
            await entered.wait()
            raise ConnectionError("synthetic lease loss")

        with patch.object(account_stream, "connection", return_value=SimpleNamespace(lock=lambda *a, **k: lease)), \
             patch.object(account_stream, "_consume", side_effect=consume, create=True), \
             patch.object(account_stream, "_renew_lease", side_effect=renew, create=True):
            await asyncio.wait_for(account_stream.stream(self.binding), 1)
        self.assertTrue(cancelled.is_set())
        lease.release.assert_called_once()

    async def test_another_worker_owning_lease_prevents_stream_and_release(self):
        lease = Mock()
        lease.acquire.return_value = False
        with patch.object(account_stream, "connection", return_value=SimpleNamespace(lock=lambda *a, **k: lease)):
            await account_stream.stream(self.binding)
        lease.release.assert_not_called()
        account_stream.connect.assert_not_called()
