#!/usr/bin/env python3
"""Small fail-closed regression for the public-browser adapter trust boundary."""
import unittest
from prepare_public_guest_browser import adapt

SOURCE = '''// Physical guest V0 acceptance: real Chromium -> TLS/Caddy -> Rust -> isolated
const exportTarget = process.argv.includes("--target")
"tools/verify_editable_export_geometry.py"
"tools/verify_temporary_guest_pdf_geometry.py"
page.locator("#temporary-delete").click()
page.locator("#temporary-start").click()
page.waitForEvent("download"
changed_download_geometry_proven:true
same_browser_session_delete_proven:true
v0_go:false
if (!/^https:\\/\\/reader\\.chaptera\\.test:\\d+$/.test(origin)) {}
const browser = await chromium.launch({
  headless: true, args: [
    "--no-proxy-server",
    "--host-resolver-rules=MAP reader.chaptera.test 127.0.0.1",
  ],
});
  ignoreHTTPSErrors: true,
    tls_caddy:true,rust_server:true,isolated_worker:true,
} finally {
  await browser.close();
}
'''


class PublicGuestAdapterTests(unittest.TestCase):
    def test_public_origin_is_strict_and_tls_validated(self):
        output = adapt(SOURCE)
        self.assertIn('origin !== "https://reader.chaptera.online"', output)
        self.assertIn('ignoreHTTPSErrors: false', output)
        self.assertIn('tls_public_trusted:true', output)
        self.assertIn('await browser.close()', output)
        self.assertIn('method: "DELETE"', output)
        self.assertNotIn('reader.chaptera.test', output)
        self.assertNotIn('host-resolver-rules', output)

    def test_missing_consumer_or_tls_marker_fails_closed(self):
        for marker in ('"tools/verify_temporary_guest_pdf_geometry.py"',
                       '  ignoreHTTPSErrors: true,',
                       'page.locator("#temporary-delete").click()'):
            with self.subTest(marker=marker):
                with self.assertRaises(ValueError):
                    adapt(SOURCE.replace(marker, ''))

    def test_duplicate_origin_marker_fails_closed(self):
        source = SOURCE.replace('  ignoreHTTPSErrors: true,',
                                '  ignoreHTTPSErrors: true,\n  ignoreHTTPSErrors: true,')
        with self.assertRaises(ValueError):
            adapt(source)


if __name__ == '__main__':
    unittest.main()
