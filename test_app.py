#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Kiểm thử đơn vị cho app.py (auth, RBAC, CSRF, Chart.js, validate input, GET/POST báo cáo)."""
import unittest
from unittest.mock import patch

import app as web


class FitLifeAppTest(unittest.TestCase):
    def setUp(self):
        web.app.config["TESTING"] = True
        self.client = web.app.test_client()

    def _login_as(self, chuc_vu="QUAN_LY", ma_nv=1, ho_ten="Test User", ma_cn=1):
        with self.client.session_transaction() as sess:
            sess["user"] = {"ma_nv": ma_nv, "ho_ten": ho_ten, "chuc_vu": chuc_vu, "ma_cn": ma_cn}
            sess["_csrf"] = "test-csrf-token"

    def test_unauthenticated_redirects_to_login(self):
        resp = self.client.get("/")
        self.assertEqual(resp.status_code, 302)
        self.assertIn("/login", resp.headers["Location"])

    def test_csrf_required_on_post(self):
        self._login_as("QUAN_LY")
        resp = self.client.post("/nhan-su/luong", data={"ma_nv": "1", "luong": "10000000"})
        self.assertEqual(resp.status_code, 403)

    def test_rbac_blocks_non_manager_on_admin_routes(self):
        self._login_as("LE_TAN")
        for path, data in [
            ("/nhan-su/luong", {"_csrf": "test-csrf-token", "ma_nv": "1", "luong": "10000000"}),
            ("/hoa-don/1/huy", {"_csrf": "test-csrf-token"}),
            ("/bao-cao/hoa-hong/tinh", {"_csrf": "test-csrf-token", "thang": "2026-10", "chot": "1"}),
        ]:
            resp = self.client.post(path, data=data)
            self.assertEqual(resp.status_code, 403, f"Expected 403 on {path}")

    @patch("app.run_sql", return_value=[{"cols": [], "rows": []}])
    def test_index_includes_chartjs_script(self, _mock_sql):
        self._login_as("QUAN_LY")
        resp = self.client.get("/")
        self.assertEqual(resp.status_code, 200)
        self.assertIn(b"chart.js", resp.data)

    @patch("app.run_sql", return_value=[{"cols": [], "rows": []}])
    def test_bao_cao_empty_int_params_no_500(self, _mock_sql):
        self._login_as("QUAN_LY")
        resp = self.client.get("/bao-cao?loai=ds_gio&gio_tu=&gio_den=&ma_cn=abc")
        self.assertEqual(resp.status_code, 200)

    @patch("app.run_sql", return_value=[{"cols": [], "rows": []}])
    def test_bao_cao_hoa_hong_get_is_readonly(self, mock_sql):
        self._login_as("QUAN_LY")
        resp = self.client.get("/bao-cao?loai=hoa_hong&thang=2026-10&chot=1")
        self.assertEqual(resp.status_code, 200)
        for call in mock_sql.call_args_list:
            self.assertNotIn("sp_TinhHoaHongThang", call.args[0])

    @patch("app.run_sql", return_value=[{"cols": ["ma_hv"], "rows": [[42]]}])
    def test_hoi_vien_them_strips_blank_email_to_none(self, mock_sql):
        self._login_as("LE_TAN")
        resp = self.client.post(
            "/hoi-vien/them",
            data={
                "_csrf": "test-csrf-token",
                "ma_the": "FL9999999",
                "ho_ten": "Nguyen Van A",
                "sdt": "0901234567",
                "email": "   ",
                "cccd": "079099000001",
                "gioi_tinh": "M",
                "ngay_sinh": "1995-01-01",
            },
        )
        self.assertEqual(resp.status_code, 302)
        params = mock_sql.call_args[0][1]
        self.assertIsNone(params[3])


if __name__ == "__main__":
    unittest.main()
