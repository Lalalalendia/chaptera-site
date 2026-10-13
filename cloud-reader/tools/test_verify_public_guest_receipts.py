#!/usr/bin/env python3
import unittest
from verify_public_guest_receipts import TARGETS, REQUIRED_TRUE, aggregate

RELEASE = "c" * 40
SOURCE = "a" * 64


def receipt(target):
    proof = {"schema": "chaptera.tempedit-real-pub-chromium-https.v1",
             "status": "PASS", "v0_go": False, "source_sha256": SOURCE,
             "export_target": target, "browser_pointer_commits": 1,
             f"changed_{target}_geometry_form": TARGETS[target],
             f"changed_{target}_geometry_proven": True,
             f"changed_{target}_identity_proven": True,
             f"changed_{target}_download_sha256": "b" * 64,
             f"changed_{target}_byte_len": 128}
    proof.update({key: True for key in REQUIRED_TRUE})
    return proof


class ReceiptTests(unittest.TestCase):
    def test_both_formats_with_delete_are_accepted_without_claiming_release_go(self):
        result = aggregate(RELEASE, SOURCE, {t: receipt(t) for t in TARGETS})
        self.assertEqual("PASS", result["status"])
        self.assertFalse(result["v0_go"])
        self.assertFalse(result["ttl_elapsed_and_physical_sweep_proven"])
        self.assertFalse(result["rollback_exercised"])
        self.assertEqual(["idml", "pdf"], [x["target"] for x in result["outputs"]])

    def test_missing_pdf_or_unsafe_success_claim_is_rejected(self):
        with self.assertRaises(ValueError):
            aggregate(RELEASE, SOURCE, {"idml": receipt("idml")})
        cases = ["no_s3_or_account", "same_browser_session_delete_proven", "tls_public_trusted"]
        for missing in cases:
            with self.subTest(missing=missing):
                data = {t: receipt(t) for t in TARGETS}
                data["pdf"][missing] = False
                with self.assertRaises(ValueError):
                    aggregate(RELEASE, SOURCE, data)

    def test_mismatched_sha_and_false_go_are_rejected(self):
        cases = {t: receipt(t) for t in TARGETS}
        cases["idml"]["v0_go"] = True
        with self.assertRaises(ValueError):
            aggregate(RELEASE, SOURCE, cases)
        cases["idml"]["v0_go"] = False
        cases["idml"]["source_sha256"] = "d" * 64
        with self.assertRaises(ValueError):
            aggregate(RELEASE, SOURCE, cases)


if __name__ == '__main__':
    unittest.main()
