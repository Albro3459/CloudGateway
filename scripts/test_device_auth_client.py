import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch


CLIENT_PATH = Path(__file__).with_name("device-auth-client.py")
spec = importlib.util.spec_from_file_location("device_auth_client", CLIENT_PATH)
assert spec is not None and spec.loader is not None
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)


class DeviceClientTests(unittest.TestCase):
    def test_proof_is_fresh_and_tokens_are_not_printed(self):
        creation = {
            "userCode": "001234", "verificationUriComplete": "https://site.example/#/auth/code",
            "deviceRequestId": "a" * 32, "expiresIn": 300, "interval": 5,
        }
        replies = [(201, creation, 0), (202, {}, 0), (200, {"customToken": "private-token"}, 0),
                   (200, {"idToken": "private-id", "refreshToken": "private-refresh"}, 0)]
        with patch.object(client, "post", side_effect=replies) as post, \
                patch.object(client.time, "sleep"), \
                patch("builtins.print") as output, \
                patch("sys.argv", ["client", "--api-origin", "https://api.example", "--firebase-api-key", "public"]):
            self.assertEqual(client.main(), 0)
        create_body = post.call_args_list[0].args[1]
        poll_body = post.call_args_list[1].args[1]
        self.assertNotIn("deviceSecret", create_body)
        raw = client.base64.urlsafe_b64decode(poll_body["deviceSecret"] + "=")
        self.assertEqual(len(raw), 32)
        self.assertEqual(create_body["deviceSecretHash"], client.hashlib.sha256(raw).hexdigest())
        self.assertEqual(post.call_args_list[3].args[1]["token"], "private-token")
        printed = str(output.call_args_list)
        for secret in (poll_body["deviceSecret"], "private-token", "private-id", "private-refresh"):
            self.assertNotIn(secret, printed)

    def test_rejected_origin_never_sends_proof(self):
        with patch.object(client, "post") as post, \
                patch("sys.argv", ["client", "--api-origin", "http://api.example", "--firebase-api-key", "public"]):
            with self.assertRaises(SystemExit):
                client.main()
        post.assert_not_called()


if __name__ == "__main__":
    unittest.main()
