import contextlib
import csv
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import xlrd
import convert_master as converter


def product(kode='1010787', barcode='8991102026352'):
    return {'Kode': kode, 'Nama': converter.TARGET, 'Barcode 1': barcode}


class ConverterTests(unittest.TestCase):
    def test_string_barcode(self):
        self.assertEqual(converter.identifier(xlrd.sheet.Cell(1, '8991102026352')), '8991102026352')

    def test_leading_zero(self):
        self.assertEqual(converter.identifier(xlrd.sheet.Cell(1, '0711844160071')), '0711844160071')

    def test_integer_barcode(self):
        self.assertEqual(converter.identifier(xlrd.sheet.Cell(2, 8991102026352.0)), '8991102026352')

    def test_fraction_rejected(self):
        with self.assertRaises(ValueError):
            converter.identifier(xlrd.sheet.Cell(2, 123.5))

    def check_error(self, xls, csv_rows, kind):
        _, errors = converter.reconcile(xls, csv_rows)
        self.assertIn(kind, [e['error_type'] for e in errors])

    def test_filled_to_empty_fails(self):
        self.check_error([product()], [product(barcode='')], 'BARCODE_MISMATCH')

    def test_different_barcode_fails(self):
        self.check_error([product()], [product(barcode='8991102026353')], 'BARCODE_MISMATCH')

    def test_removed_zero_fails(self):
        self.check_error([product(barcode='0711844160071')],
                         [product(barcode='711844160071')], 'BARCODE_MISMATCH')

    def test_missing_plu_fails(self):
        self.check_error([product()], [], 'PLU_HILANG')

    def test_extra_plu_fails(self):
        self.check_error([], [product()], 'PLU_TAMBAHAN')

    def test_duplicate_xls_fails(self):
        self.check_error([product(), product()], [product()], 'DUPLICATE_PLU_XLS')

    def test_duplicate_csv_fails(self):
        self.check_error([product()], [product(), product()], 'DUPLICATE_PLU_CSV')

    def test_exact_and_empty_pass(self):
        rows = [product(), product('002', ''), product('003', '0711844160071')]
        stats, errors = converter.reconcile(rows, list(reversed(rows)))
        self.assertEqual(errors, [])
        self.assertEqual(stats['XLS barcode kosong'], 1)
        self.assertEqual(stats['CSV PLU unik'], 3)

    def test_invalid_csv_kode(self):
        for kode in ['1E+6', '1E-6', '123.0', 'nan', 'null']:
            with self.subTest(kode=kode):
                self.check_error([product()], [product(kode)], 'INVALID_CSV')

    def test_failure_preserves_previous_output_and_reports(self):
        source = Path(__file__).with_name('23.xls')
        original_read = converter.read_csv

        def corrupted_read(path):
            rows = original_read(path)
            next(r for r in rows if r['Kode'] == '1010787')['Barcode 1'] = ''
            return rows

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / 'master_barang_safe.csv'
            output.write_bytes(b'previous valid output')
            with patch.object(converter, '__file__', str(root / 'convert_master.py')), \
                    patch.object(converter, 'read_csv', side_effect=corrupted_read), \
                    contextlib.redirect_stdout(io.StringIO()):
                result, _ = converter.convert(source, output)
            self.assertNotEqual(result, 0)
            self.assertEqual(output.read_bytes(), b'previous valid output')
            with (root / 'conversion_validation_errors.csv').open(encoding='utf-8', newline='') as stream:
                errors = list(csv.DictReader(stream))
            mismatch = next(e for e in errors if e['error_type'] == 'BARCODE_MISMATCH')
            self.assertEqual(mismatch['kode'], '1010787')
            self.assertEqual(mismatch['xls_barcode'], '8991102026352')
            self.assertEqual(mismatch['csv_barcode'], '')
            self.assertEqual(list(root.glob('*.tmp')), [])


if __name__ == '__main__':
    unittest.main()
