"""
Practical connection tests for the Sound Effect Generator.

These tests verify that each API endpoint is reachable and responds correctly
to authentication checks — without generating real audio (no credits consumed).

Run:
    # With real keys (reads from .env in the repo root):
    python 8_Test/test_connections.py

    # Or with environment variables:
    ELEVENLABS_API_KEY=sk_... FAL_API_KEY=fal_... XAI_API_KEY=xai-... \
        python 8_Test/test_connections.py

    # Run via unittest:
    python -m pytest 8_Test/test_connections.py -v
    python -m unittest 8_Test/test_connections.py -v
"""

import os
import sys
import json
import unittest
from pathlib import Path

try:
    import urllib.request as urllib_request
    import urllib.error as urllib_error
except ImportError:
    print("Python 3.x required", file=sys.stderr)
    sys.exit(1)

# ─── Load .env from repo root ─────────────────────────────────────────────────
_REPO_ROOT = Path(__file__).resolve().parent.parent
_ENV_FILE = _REPO_ROOT / ".env"

def _load_env_file(path: Path) -> None:
    """Load KEY=value pairs from a .env file into os.environ (skip if missing)."""
    if not path.exists():
        return
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.split("#")[0].strip()  # strip inline comments
                if key and key not in os.environ:    # don't override existing env
                    os.environ[key] = value

_load_env_file(_ENV_FILE)

# ─── Helpers ──────────────────────────────────────────────────────────────────
TIMEOUT = 15  # seconds


def _http_get(url: str, headers: dict) -> tuple[int, dict | None]:
    """Perform a GET request; returns (status_code, json_body_or_None)."""
    req = urllib_request.Request(url, headers=headers)
    try:
        with urllib_request.urlopen(req, timeout=TIMEOUT) as resp:
            status = resp.status
            body = json.loads(resp.read().decode())
            return status, body
    except urllib_error.HTTPError as e:
        body = None
        try:
            body = json.loads(e.read().decode())
        except Exception:
            pass
        return e.code, body
    except Exception as e:
        raise ConnectionError(f"Request failed: {e}") from e


def _http_post(url: str, headers: dict, payload: dict) -> tuple[int, dict | None]:
    """Perform a POST request with a JSON payload; returns (status_code, json_body_or_None)."""
    data = json.dumps(payload).encode()
    headers = {**headers, "Content-Type": "application/json"}
    req = urllib_request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib_request.urlopen(req, timeout=TIMEOUT) as resp:
            body = json.loads(resp.read().decode())
            return resp.status, body
    except urllib_error.HTTPError as e:
        body = None
        try:
            body = json.loads(e.read().decode())
        except Exception:
            pass
        return e.code, body
    except Exception as e:
        raise ConnectionError(f"Request failed: {e}") from e


# ─── Test Cases ───────────────────────────────────────────────────────────────
class TestElevenLabsConnection(unittest.TestCase):
    """Tests for ElevenLabs API connectivity."""

    @classmethod
    def setUpClass(cls):
        cls.api_key = os.environ.get("ELEVENLABS_API_KEY", "")

    def test_key_is_configured(self):
        """ELEVENLABS_API_KEY must be set (non-empty)."""
        if not self.api_key:
            self.skipTest("ELEVENLABS_API_KEY is not set. Add it to your .env file or environment.")
        self.assertTrue(self.api_key)

    @unittest.skipUnless(os.environ.get("ELEVENLABS_API_KEY"), "ELEVENLABS_API_KEY not set")
    def test_user_endpoint_returns_200(self):
        """/v1/user returns HTTP 200 with a valid key."""
        status, body = _http_get(
            "https://api.elevenlabs.io/v1/user",
            {"xi-api-key": self.api_key}
        )
        self.assertEqual(status, 200, f"Expected 200, got {status}. Body: {body}")

    @unittest.skipUnless(os.environ.get("ELEVENLABS_API_KEY"), "ELEVENLABS_API_KEY not set")
    def test_user_response_has_subscription(self):
        """/v1/user response contains subscription information."""
        status, body = _http_get(
            "https://api.elevenlabs.io/v1/user",
            {"xi-api-key": self.api_key}
        )
        self.assertEqual(status, 200)
        self.assertIsNotNone(body, "Response body should not be None")
        self.assertIn("subscription", body, "Response should contain 'subscription' key")

    @unittest.skipUnless(os.environ.get("ELEVENLABS_API_KEY"), "ELEVENLABS_API_KEY not set")
    def test_invalid_key_returns_401(self):
        """An invalid key must return HTTP 401 Unauthorized."""
        status, _ = _http_get(
            "https://api.elevenlabs.io/v1/user",
            {"xi-api-key": "invalid_key_for_testing"}
        )
        self.assertEqual(status, 401, f"Expected 401 for invalid key, got {status}")


class TestFalConnection(unittest.TestCase):
    """Tests for fal.ai API connectivity."""

    @classmethod
    def setUpClass(cls):
        cls.api_key = os.environ.get("FAL_API_KEY", "")

    def test_key_is_configured(self):
        """FAL_API_KEY must be set (non-empty)."""
        if not self.api_key:
            self.skipTest("FAL_API_KEY is not set. Add it to your .env file or environment.")
        self.assertTrue(self.api_key)

    @unittest.skipUnless(os.environ.get("FAL_API_KEY"), "FAL_API_KEY not set")
    def test_auth_does_not_return_401_or_403(self):
        """A POST with valid credentials should not return 401 or 403."""
        status, body = _http_post(
            "https://fal.run/fal-ai/stable-audio",
            {"Authorization": f"Key {self.api_key}"},
            {"prompt": "test connection ping", "seconds_total": 1}
        )
        self.assertNotIn(
            status, [401, 403],
            f"Auth failed with HTTP {status}. Body: {body}"
        )

    @unittest.skipUnless(os.environ.get("FAL_API_KEY"), "FAL_API_KEY not set")
    def test_invalid_key_returns_401_or_403(self):
        """An invalid key must return HTTP 401 or 403."""
        status, _ = _http_post(
            "https://fal.run/fal-ai/stable-audio",
            {"Authorization": "Key invalid_key_for_testing"},
            {"prompt": "test", "seconds_total": 1}
        )
        self.assertIn(
            status, [401, 403],
            f"Expected 401/403 for invalid key, got {status}"
        )


class TestXaiConnection(unittest.TestCase):
    """Tests for Grok/xAI API connectivity."""

    @classmethod
    def setUpClass(cls):
        cls.api_key = os.environ.get("XAI_API_KEY", "")

    def test_key_is_configured(self):
        """XAI_API_KEY must be set (non-empty)."""
        if not self.api_key:
            self.skipTest("XAI_API_KEY is not set. Add it to your .env file or environment.")
        self.assertTrue(self.api_key)

    @unittest.skipUnless(os.environ.get("XAI_API_KEY"), "XAI_API_KEY not set")
    def test_models_endpoint_returns_200(self):
        """/v1/models returns HTTP 200 with a valid key."""
        status, body = _http_get(
            "https://api.x.ai/v1/models",
            {"Authorization": f"Bearer {self.api_key}"}
        )
        self.assertEqual(status, 200, f"Expected 200, got {status}. Body: {body}")

    @unittest.skipUnless(os.environ.get("XAI_API_KEY"), "XAI_API_KEY not set")
    def test_models_response_contains_data(self):
        """/v1/models response contains a 'data' array with at least one model."""
        status, body = _http_get(
            "https://api.x.ai/v1/models",
            {"Authorization": f"Bearer {self.api_key}"}
        )
        self.assertEqual(status, 200)
        self.assertIsNotNone(body)
        self.assertIn("data", body, "Response should contain 'data' key")
        self.assertIsInstance(body["data"], list)
        self.assertGreater(len(body["data"]), 0, "Should list at least one model")

    @unittest.skipUnless(os.environ.get("XAI_API_KEY"), "XAI_API_KEY not set")
    def test_grok_model_is_available(self):
        """At least one grok model should be listed."""
        status, body = _http_get(
            "https://api.x.ai/v1/models",
            {"Authorization": f"Bearer {self.api_key}"}
        )
        self.assertEqual(status, 200)
        model_ids = [m.get("id", "") for m in body.get("data", [])]
        grok_models = [m for m in model_ids if "grok" in m.lower()]
        self.assertTrue(grok_models, f"No grok model found. Available: {model_ids}")

    @unittest.skipUnless(os.environ.get("XAI_API_KEY"), "XAI_API_KEY not set")
    def test_invalid_key_returns_401(self):
        """An invalid key must return HTTP 401 Unauthorized."""
        status, _ = _http_get(
            "https://api.x.ai/v1/models",
            {"Authorization": "Bearer invalid_key_for_testing"}
        )
        self.assertEqual(status, 401, f"Expected 401 for invalid key, got {status}")


class TestEnvConfiguration(unittest.TestCase):
    """Tests for local environment configuration."""

    def test_env_example_exists(self):
        """.env.example file must exist in the repo root."""
        env_example = _REPO_ROOT / ".env.example"
        self.assertTrue(env_example.exists(), ".env.example not found in repo root")

    def test_env_example_has_required_keys(self):
        """.env.example must define all required API key variables."""
        env_example = _REPO_ROOT / ".env.example"
        if not env_example.exists():
            self.skipTest(".env.example not found")
        content = env_example.read_text()
        required = ["ELEVENLABS_API_KEY", "FAL_API_KEY", "XAI_API_KEY", "BACKEND", "VARIANTS"]
        for key in required:
            self.assertIn(key, content, f"'{key}' not found in .env.example")

    def test_env_is_gitignored(self):
        """.env must appear in .gitignore to prevent accidental secret commits."""
        gitignore = _REPO_ROOT / ".gitignore"
        self.assertTrue(gitignore.exists(), ".gitignore not found")
        content = gitignore.read_text()
        self.assertRegex(
            content,
            r"(^|\n)\.env(\s|$)",
            ".env is not listed in .gitignore"
        )

    def test_index_html_exists(self):
        """index.html must exist in the repo root."""
        index = _REPO_ROOT / "index.html"
        self.assertTrue(index.exists(), "index.html not found in repo root")

    def test_soundfx_sh_exists(self):
        """soundfx.sh must exist in the repo root."""
        sh = _REPO_ROOT / "soundfx.sh"
        self.assertTrue(sh.exists(), "soundfx.sh not found in repo root")

    def test_soundfx_ps1_exists(self):
        """soundfx.ps1 must exist in the repo root."""
        ps1 = _REPO_ROOT / "soundfx.ps1"
        self.assertTrue(ps1.exists(), "soundfx.ps1 not found in repo root")

    def test_soundfx_sh_is_executable(self):
        """soundfx.sh must be executable."""
        sh = _REPO_ROOT / "soundfx.sh"
        if not sh.exists():
            self.skipTest("soundfx.sh not found")
        self.assertTrue(
            os.access(sh, os.X_OK),
            "soundfx.sh is not executable (run: chmod +x soundfx.sh)"
        )


class TestIndexHtmlContent(unittest.TestCase):
    """Tests that verify index.html contains required UI features."""

    @classmethod
    def setUpClass(cls):
        index = _REPO_ROOT / "index.html"
        cls.content = index.read_text() if index.exists() else ""

    def test_has_elevenlabs_key_input(self):
        """index.html must contain an ElevenLabs API key input."""
        self.assertIn("elevenlabs-key", self.content)

    def test_has_fal_key_input(self):
        """index.html must contain a fal.ai API key input."""
        self.assertIn("fal-key", self.content)

    def test_has_xai_key_input(self):
        """index.html must contain a Grok/xAI API key input."""
        self.assertIn("xai-key", self.content)

    def test_has_backend_toggle(self):
        """index.html must contain a backend selector."""
        self.assertIn("backend-select", self.content)

    def test_has_analyse_button(self):
        """index.html must contain the Analyse Script button."""
        self.assertIn("analyseScript", self.content)

    def test_has_generate_all_button(self):
        """index.html must contain the Generate All button."""
        self.assertIn("generateAll", self.content)

    def test_has_connection_tests(self):
        """index.html must contain connection test functionality."""
        self.assertIn("testConnection", self.content)

    def test_has_cookie_persistence(self):
        """index.html must use cookies for key persistence."""
        self.assertIn("setCookie", self.content)
        self.assertIn("getCookie", self.content)

    def test_has_audio_player_logic(self):
        """index.html must include audio generation and playback logic."""
        self.assertIn("generateVariants", self.content)
        self.assertIn("<audio", self.content)

    def test_has_elevenlabs_api_call(self):
        """index.html must call the ElevenLabs sound-generation endpoint."""
        self.assertIn("elevenlabs.io/v1/sound-generation", self.content)

    def test_has_fal_api_call(self):
        """index.html must call the fal.ai stable-audio endpoint."""
        self.assertIn("fal.run/fal-ai/stable-audio", self.content)

    def test_has_xai_api_call(self):
        """index.html must call the xAI chat completions endpoint."""
        self.assertIn("api.x.ai/v1/chat/completions", self.content)


class TestShellScriptContent(unittest.TestCase):
    """Tests that verify soundfx.sh contains required functionality."""

    @classmethod
    def setUpClass(cls):
        sh = _REPO_ROOT / "soundfx.sh"
        cls.content = sh.read_text() if sh.exists() else ""

    def test_has_env_loading(self):
        """soundfx.sh must load .env file."""
        self.assertIn(".env", self.content)

    def test_has_connection_test_flag(self):
        """soundfx.sh must support --test flag."""
        self.assertIn("--test", self.content)

    def test_has_generate_flag(self):
        """soundfx.sh must support --generate flag."""
        self.assertIn("--generate", self.content)

    def test_has_grok_api_call(self):
        """soundfx.sh must call the xAI API."""
        self.assertIn("api.x.ai", self.content)

    def test_has_elevenlabs_generation(self):
        """soundfx.sh must call ElevenLabs sound-generation endpoint."""
        self.assertIn("elevenlabs.io/v1/sound-generation", self.content)

    def test_has_fal_generation(self):
        """soundfx.sh must call fal.ai stable-audio endpoint."""
        self.assertIn("fal.run/fal-ai/stable-audio", self.content)

    def test_has_variants_option(self):
        """soundfx.sh must support --variants option."""
        self.assertIn("--variants", self.content)

    def test_has_dep_check(self):
        """soundfx.sh must check for required dependencies."""
        self.assertIn("check_deps", self.content)


class TestPowerShellScriptContent(unittest.TestCase):
    """Tests that verify soundfx.ps1 contains required functionality."""

    @classmethod
    def setUpClass(cls):
        ps1 = _REPO_ROOT / "soundfx.ps1"
        cls.content = ps1.read_text() if ps1.exists() else ""

    def test_has_env_loading(self):
        """soundfx.ps1 must load .env file."""
        self.assertIn("Load-EnvFile", self.content)

    def test_has_test_switch(self):
        """soundfx.ps1 must support -Test switch."""
        self.assertIn("-Test", self.content)

    def test_has_generate_switch(self):
        """soundfx.ps1 must support -Generate switch."""
        self.assertIn("-Generate", self.content)

    def test_has_grok_api_call(self):
        """soundfx.ps1 must call the xAI API."""
        self.assertIn("api.x.ai", self.content)

    def test_has_elevenlabs_generation(self):
        """soundfx.ps1 must call ElevenLabs sound-generation endpoint."""
        self.assertIn("elevenlabs.io/v1/sound-generation", self.content)

    def test_has_fal_generation(self):
        """soundfx.ps1 must call fal.ai stable-audio endpoint."""
        self.assertIn("fal.run/fal-ai/stable-audio", self.content)

    def test_has_variants_param(self):
        """soundfx.ps1 must support -Variants parameter."""
        self.assertIn("Variants", self.content)

    def test_has_connection_test_functions(self):
        """soundfx.ps1 must include connection test functions."""
        self.assertIn("Test-ElevenLabsConnection", self.content)
        self.assertIn("Test-FalConnection", self.content)
        self.assertIn("Test-XaiConnection", self.content)


# ─── CLI runner ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    # Run with verbose output when executed directly
    unittest.main(verbosity=2)
