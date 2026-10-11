"""Independent ZIP readers validate byte and metadata preservation across atomic addition."""
import ctypes as C
import os
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

LIB = C.CDLL(os.environ['ARKIV_TEST_LIBRARY'])
LIB.arkiv_zip_begin.argtypes = [C.c_char_p, C.c_char_p, C.c_size_t]
LIB.arkiv_zip_begin.restype = C.c_void_p
LIB.arkiv_zip_end.argtypes = [C.c_void_p]
LIB.arkiv_zip_prepare.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p, C.c_void_p, C.c_void_p, C.c_void_p, C.c_char_p, C.c_size_t]
LIB.arkiv_zip_commit.argtypes = [C.c_void_p, C.c_void_p, C.c_char_p, C.c_size_t]
LIB.arkiv_cancel_new.restype = C.c_void_p
LIB.arkiv_cancel_set.argtypes = [C.c_void_p]
LIB.arkiv_cancel_free.argtypes = [C.c_void_p]

class AdditionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.original = self.root / 'original.zip'
        self.addition = self.root / 'addition.zip'
        self.stage = self.root / 'stage'
        self.stage.mkdir(mode=0o700)
        with zipfile.ZipFile(self.original, 'w') as z:
            entry = zipfile.ZipInfo('nested/original.txt')
            entry.extra = struct.pack('<HHBI', 0x5455, 5, 1, 1234567890)
            entry.comment = b'entry comment \x00 binary'
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100640 << 16
            z.writestr(entry, b'original data' * 100)
            z.comment = b'archive comment \x00 preserved'
        os.chmod(self.original, 0o640)
        with zipfile.ZipFile(self.addition, 'w') as z:
            z.writestr('資料/empty/', b'')
            z.writestr('資料/added.txt', 'added')
        self.before = self.original.read_bytes()
        self.error = C.create_string_buffer(256)
        self.transaction = LIB.arkiv_zip_begin(os.fsencode(self.original), self.error, 256)
        self.assertTrue(self.transaction, self.error.value)
    def tearDown(self):
        LIB.arkiv_zip_end(self.transaction)
        self.tmp.cleanup()
    def prepare(self):
        return LIB.arkiv_zip_prepare(self.transaction, os.fsencode(self.addition), os.fsencode(self.stage), None, None, None, self.error, 256)
    def test_raw_records_comments_extra_permissions_preserved(self):
        self.assertEqual(self.prepare(), 0, self.error.value)
        self.assertEqual(self.original.read_bytes(), self.before)
        self.assertEqual(LIB.arkiv_zip_commit(self.transaction, None, self.error, 256), 0, self.error.value)
        after = self.original.read_bytes()
        offset = self.before.index(b'PK\x01\x02')
        self.assertEqual(after[:offset], self.before[:offset])
        self.assertEqual(self.original.stat().st_mode & 0o777, 0o640)
        with zipfile.ZipFile(self.original) as z:
            self.assertIsNone(z.testzip())
            self.assertEqual(z.read('nested/original.txt'), b'original data' * 100)
            self.assertEqual(z.comment, b'archive comment \x00 preserved')
            entry = z.getinfo('nested/original.txt')
            self.assertEqual(entry.comment, b'entry comment \x00 binary')
            self.assertEqual(entry.extra, struct.pack('<HHBI', 0x5455, 5, 1, 1234567890))
            self.assertEqual(entry.external_attr, 0o100640 << 16)
            self.assertEqual(z.read('資料/added.txt'), b'added')
        self.assertEqual(list(self.stage.iterdir()), [])
    def test_cancel_before_commit_preserves_original(self):
        self.assertEqual(self.prepare(), 0)
        token = LIB.arkiv_cancel_new()
        try:
            LIB.arkiv_cancel_set(token)
            self.assertEqual(LIB.arkiv_zip_commit(self.transaction, token, self.error, 256), 2)
            self.assertEqual(self.original.read_bytes(), self.before)
        finally: LIB.arkiv_cancel_free(token)
    def test_changed_original_or_replacement_is_rejected(self):
        self.assertEqual(self.prepare(), 0)
        replacement = self.stage / 'replacement.zip'
        replacement.write_bytes(b'changed')
        self.assertEqual(LIB.arkiv_zip_commit(self.transaction, None, self.error, 256), 1)
        self.assertEqual(self.original.read_bytes(), self.before)
    def test_corruption_never_commits(self):
        broken = bytearray(self.before)
        payload = 30 + struct.unpack_from('<H', broken, 26)[0] + struct.unpack_from('<H', broken, 28)[0]
        broken[payload] ^= 0xff
        self.original.write_bytes(broken)
        self.assertEqual(self.prepare(), 1)
        self.assertEqual(LIB.arkiv_zip_commit(self.transaction, None, self.error, 256), 1)
        self.assertEqual(self.original.read_bytes(), broken)
    def test_nonzip_unknown_metadata_and_symlink_are_readonly(self):
        for name, data in [('renamed.zip', b'7z\xbc\xaf\x27\x1c' + b'\0'*100), ('opaque.zip', None)]:
            path = self.root / name
            if data: path.write_bytes(data)
            else:
                with zipfile.ZipFile(path, 'w') as z:
                    info = zipfile.ZipInfo('opaque')
                    info.extra = struct.pack('<HHI', 0x1234, 4, 0)
                    z.writestr(info, b'data')
            t = LIB.arkiv_zip_begin(os.fsencode(path), self.error, 256)
            if t: LIB.arkiv_zip_end(t)
            self.assertFalse(t)
        alias = self.root / 'alias'
        alias.symlink_to(self.root, target_is_directory=True)
        self.assertFalse(LIB.arkiv_zip_begin(os.fsencode(alias / 'original.zip'), self.error, 256))

if __name__ == '__main__': unittest.main()
