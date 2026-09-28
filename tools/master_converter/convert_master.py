"""Read original XLS cell values, validate, then publish a UTF-8 master CSV.

Usage: python convert_master.py [input.xls] [--output output.csv]
Defaults are relative to this script. No Excel/COM or display formatting is used.
Text identifiers retain leading zeros; only surrounding whitespace is removed.
Numeric identifiers cannot recover zeros/precision already lost in the XLS value.
Errors prevent publication; an existing output is left untouched on failure.
"""

import argparse
import csv
from collections import Counter
from decimal import Decimal, InvalidOperation
import hashlib
import io
import math
from pathlib import Path
import re
import tempfile
import sys

import xlrd


# Type alias for conversion result
ConversionResult = tuple[int, dict | None]  # (return_code, stats or None)


HEADERS = ['Kode', 'Nama', 'QTY', 'UNIT', 'Hrg Sat 1', 'Barcode 1']
TARGET = 'CRYSTALLINE PET 600 ML'
EXPECTED = '8991102026352'
EMPTY_TYPES = (xlrd.XL_CELL_EMPTY, xlrd.XL_CELL_BLANK)


def validate_identifier(value, required=False):
    if not isinstance(value, str):
        raise ValueError('identifier harus string')
    if required and not value:
        raise ValueError('Kode kosong')
    if re.search(r'e[+-]', value, re.IGNORECASE):
        raise ValueError(f'notasi scientific tidak diizinkan: {value!r}')
    if value.casefold() in {'nan', 'null', 'none', 'inf', 'infinity'}:
        raise ValueError(f'identifier tidak valid: {value!r}')
    if '.0' in value:
        raise ValueError(f'identifier mengandung .0: {value!r}')


def identifier(cell, required=False):
    if cell.ctype in EMPTY_TYPES:
        result = ''
    elif cell.ctype == xlrd.XL_CELL_TEXT:
        result = cell.value.strip()
    elif cell.ctype == xlrd.XL_CELL_NUMBER:
        value = cell.value
        if not math.isfinite(value) or not value.is_integer():
            raise ValueError(f'numeric identifier bukan integer exact: {value!r}')
        if abs(value) >= 2**53:
            raise ValueError(f'numeric identifier di luar rentang integer aman: {value!r}')
        if value < 0:
            raise ValueError(f'numeric identifier negatif: {value!r}')
        result = str(int(value))
    else:
        raise ValueError(f'tipe cell identifier tidak didukung: {cell.ctype}')
    validate_identifier(result, required)
    return result


def text_cell(cell):
    if cell.ctype in EMPTY_TYPES:
        return ''
    if cell.ctype != xlrd.XL_CELL_TEXT:
        raise ValueError(f'cell teks memiliki tipe {cell.ctype}')
    return cell.value.strip()


def numeric(cell):
    if cell.ctype in EMPTY_TYPES or (
        cell.ctype == xlrd.XL_CELL_TEXT and not cell.value.strip()
    ):
        raise ValueError('nilai numerik kosong; tidak menebak nol')
    if cell.ctype not in (xlrd.XL_CELL_NUMBER, xlrd.XL_CELL_TEXT):
        raise ValueError(f'tipe cell numerik tidak didukung: {cell.ctype}')
    value = str(cell.value).strip()
    # Accept plain decimal/scientific numeric values, not ambiguous separators.
    if not re.fullmatch(r'[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?', value):
        raise ValueError(f'nilai numerik tidak valid: {value!r}')
    try:
        number = Decimal(value)
    except InvalidOperation as exc:
        raise ValueError(f'nilai numerik tidak valid: {value!r}') from exc
    if not number.is_finite() or not math.isfinite(float(number)):
        raise ValueError(f'nilai numerik tidak finite: {value!r}')
    return format(number, 'f')


def header_key(value):
    return re.sub(r'\s+', '', str(value)).casefold()


ERROR_HEADERS = ['error_type', 'kode', 'nama', 'xls_barcode', 'csv_barcode', 'detail']


def issue(kind, kode='', nama='', xls_barcode='', csv_barcode='', detail=''):
    return dict(zip(ERROR_HEADERS, [kind, kode, nama, xls_barcode, csv_barcode, detail]))


def reconcile(xls_rows, csv_rows):
    """Compare independently read XLS identifiers with serialized CSV, keyed by PLU."""
    errors = []
    xc = Counter(row['Kode'] for row in xls_rows)
    cc = Counter(row['Kode'] for row in csv_rows)
    missing, extra = set(xc) - set(cc), set(cc) - set(xc)
    stats = {
        'XLS rows': len(xls_rows), 'CSV rows': len(csv_rows),
        'XLS PLU unik': len(xc), 'CSV PLU unik': len(cc),
        'XLS barcode terisi': sum(bool(r['Barcode 1']) for r in xls_rows),
        'CSV barcode terisi': sum(bool(r['Barcode 1']) for r in csv_rows),
        'XLS barcode kosong': sum(not r['Barcode 1'] for r in xls_rows),
        'CSV barcode kosong': sum(not r['Barcode 1'] for r in csv_rows),
        'PLU hilang': len(missing), 'PLU tambahan': len(extra),
        'Duplicate PLU XLS': sum(n - 1 for n in xc.values()),
        'Duplicate PLU CSV': sum(n - 1 for n in cc.values()),
        'Barcode mismatch': 0, 'Kode mismatch': len(missing) + len(extra),
    }
    for label, rows, counts in [('XLS', xls_rows, xc), ('CSV', csv_rows, cc)]:
        for row in rows:
            kode, barcode = row['Kode'], row['Barcode 1']
            for field, value in [('Kode', kode), ('Barcode 1', barcode)]:
                try:
                    validate_identifier(value, required=field == 'Kode')
                except ValueError as exc:
                    errors.append(issue('INVALID_' + label, kode, row['Nama'],
                                        detail=f'{field}: {exc}'))
            if counts[kode] > 1:
                errors.append(issue('DUPLICATE_PLU_' + label, kode, row['Nama'],
                                    detail=f'{counts[kode]} rows memiliki PLU yang sama'))
    xmap = {row['Kode']: row for row in xls_rows}
    cmap = {row['Kode']: row for row in csv_rows}
    for kode in sorted(missing):
        row = xmap[kode]
        errors.append(issue('PLU_HILANG', kode, row['Nama'], row['Barcode 1']))
    for kode in sorted(extra):
        row = cmap[kode]
        errors.append(issue('PLU_TAMBAHAN', kode, row['Nama'], csv_barcode=row['Barcode 1']))
    for kode in sorted(set(xc) & set(cc)):
        if xc[kode] != 1 or cc[kode] != 1:
            continue  # Duplicate already fails; do not guess which product to match.
        x, c = xmap[kode], cmap[kode]
        if x['Barcode 1'] != c['Barcode 1']:
            stats['Barcode mismatch'] += 1
            errors.append(issue('BARCODE_MISMATCH', kode, x['Nama'],
                                x['Barcode 1'], c['Barcode 1'], 'Exact string berbeda'))
    if len(xls_rows) != len(csv_rows):
        errors.append(issue('ROW_COUNT', detail='Jumlah row XLS dan CSV berbeda'))
    return stats, errors


def read_csv(path):
    with path.open(encoding='utf-8', newline='') as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames != HEADERS:
            raise ValueError('Header CSV berubah')
        rows = list(reader)
    if any(None in row or any(v is None for v in row.values()) for row in rows):
        raise ValueError('Jumlah kolom CSV tidak valid')
    return rows


def convert(source, destination):
    errors, rows, source_rows = [], [], []
    workbook = temporary = None
    stats = None
    reader_log = io.StringIO()
    report = Path(__file__).resolve().parent / 'conversion_validation_errors.csv'
    try:
        if source.resolve() == destination.resolve() or destination.suffix.lower() != '.csv':
            raise ValueError('Output harus CSV dan berbeda dari file XLS')
        if destination.resolve() == report.resolve() or source.resolve() == report.resolve():
            raise ValueError('Path sumber/output bertabrakan dengan laporan error')
        original_hash = hashlib.sha256(source.read_bytes()).hexdigest()
        workbook = xlrd.open_workbook(str(source), logfile=reader_log)
        matches = []
        for sheet in workbook.sheets():
            for row_index in range(min(30, sheet.nrows)):
                keys = [header_key(v) for v in sheet.row_values(row_index)]
                if all(header_key(h) in keys for h in HEADERS):
                    if any(keys.count(header_key(h)) != 1 for h in HEADERS):
                        raise ValueError('Header master duplikat')
                    matches.append((sheet, row_index, [keys.index(header_key(h)) for h in HEADERS]))
        if len(matches) != 1:
            raise ValueError(f'Harus ada tepat satu tabel master; ditemukan {len(matches)}')
        sheet, header_row, columns = matches[0]
        # Independent reference from original cells, never from output row values.
        for index in range(header_row + 1, sheet.nrows):
            cells = [sheet.cell(index, col) for col in columns]
            if all(c.ctype in EMPTY_TYPES or str(c.value).strip() == '' for c in cells):
                continue
            try:
                kode = identifier(cells[0], required=True)
                source_rows.append({'Kode': kode, 'Nama': str(cells[1].value).strip(),
                                    'Barcode 1': identifier(cells[5])})
            except ValueError as exc:
                errors.append(issue('XLS_INVALID', str(cells[0].value), str(cells[1].value),
                                    str(cells[5].value), detail=f'Baris XLS {index + 1}: {exc}'))
            try:
                row = [identifier(cells[0], required=True), text_cell(cells[1]),
                       numeric(cells[2]), text_cell(cells[3]), numeric(cells[4]), identifier(cells[5])]
                if not row[1]:
                    raise ValueError('Nama kosong')
                rows.append(row)
            except ValueError as exc:
                errors.append(issue('CONVERSION', str(cells[0].value), str(cells[1].value),
                                    str(cells[5].value), detail=f'Baris XLS {index + 1}: {exc}'))
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', newline='',
                                         dir=destination.parent, suffix='.tmp', delete=False) as out:
            temporary = Path(out.name)
            writer = csv.writer(out, quoting=csv.QUOTE_ALL)
            writer.writerow(HEADERS)
            writer.writerows(rows)
        written = read_csv(temporary)
        stats, mismatches = reconcile(source_rows, written)
        errors.extend(mismatches)
        # Keep full serialization round-trip check as well as per-PLU reconciliation.
        if written != [dict(zip(HEADERS, row)) for row in rows]:
            errors.append(issue('CSV_ROUND_TRIP', detail='Data CSV berubah saat serialisasi'))
        for label, records in [('XLS', source_rows), ('CSV', written)]:
            target = [r for r in records if r['Kode'] == '1010787']
            if (len(target) != 1 or target[0]['Nama'].upper() != TARGET
                    or target[0]['Barcode 1'] != EXPECTED):
                errors.append(issue('CRYSTALLINE_' + label, '1010787', TARGET,
                                    detail=f'{label}: harus tepat satu PLU dengan barcode {EXPECTED}'))
            else:
                print(f'{label}: {TARGET} | Kode 1010787 | Barcode {target[0]["Barcode 1"]}')
        if hashlib.sha256(source.read_bytes()).hexdigest() != original_hash:
            errors.append(issue('SOURCE_CHANGED', detail='Hash sumber XLS berubah'))
        if not errors:
            temporary.replace(destination)
            temporary = None
    except (ValueError, OSError, xlrd.XLRDError) as exc:
        errors.append(issue('CONVERSION', detail=str(exc)))
    finally:
        if workbook is not None:
            workbook.release_resources()
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    warnings = [line for line in reader_log.getvalue().splitlines() if line.strip()]
    for warning in warnings:
        print(f'WARNING: {warning}')
    print('=== VALIDASI MASTER ===')
    if stats is not None:
        for key, value in stats.items():
            print(f'{key:24}: {value}')
    print(f'Warning                 : {len(warnings)}')
    print(f'Error                   : {len(errors)}')
    if errors:
        with report.open('w', encoding='utf-8', newline='') as stream:
            writer = csv.DictWriter(stream, fieldnames=ERROR_HEADERS)
            writer.writeheader()
            writer.writerows(errors)
        for error in errors[:10]:
            print('ERROR ' + error['error_type'])
            for key in ERROR_HEADERS[1:]:
                print(f'  {key}: {error[key] or "<KOSONG>"}')
        print(f'GAGAL: output sebelumnya tidak diganti. Semua error: {report}')
        return 1, stats
    # A header-only report explicitly clears stale errors from a previous run.
    with report.open('w', encoding='utf-8', newline='') as stream:
        csv.DictWriter(stream, fieldnames=ERROR_HEADERS).writeheader()
    print('VALID - CSV setara dengan XLS untuk Kode dan Barcode.')
    print(f'Output: {destination.resolve()}')
    return 0, stats


def main():
    base = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', nargs='?', type=Path, default=base / '23.xls')
    parser.add_argument('--output', type=Path, default=base / 'master_barang_safe.csv')
    args = parser.parse_args()
    return_code, _ = convert(args.input, args.output)
    return return_code


if __name__ == '__main__':
    raise SystemExit(main())
